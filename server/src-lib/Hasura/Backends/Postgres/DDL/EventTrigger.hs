{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Postgres DDL EventTrigger
--
-- Used for creating event triggers for metadata changes.
--
-- See 'Hasura.RQL.DDL.Schema.Cache' and 'Hasura.RQL.Types.Eventing.Backend'.
module Hasura.Backends.Postgres.DDL.EventTrigger
  ( insertManualEvent,
    redeliverEvent,
    dropTriggerAndArchiveEvents,
    createTableEventTrigger,
    createMissingSQLTriggers,
    dropTriggerQ,
    dropDanglingSQLTrigger,
    mkAllTriggersQ,
    getMaintenanceModeVersion,
    fetchUndeliveredEvents,
    setRetry,
    recordSuccess,
    recordError,
    recordError',
    unlockEventsInSource,
    updateColumnInEventTrigger,
    checkIfTriggerExists,
    deleteEventTriggerLogs,
  )
where

import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Aeson
import Data.FileEmbed (makeRelativeToProject)
import Data.HashSet qualified as HashSet
import Data.Int (Int64)
import Data.Set.NonEmpty qualified as NE
import Data.Text.Lazy qualified as TL
import Data.Time.Clock qualified as Time
import Database.PG.Query qualified as Q
import Hasura.Backends.Postgres.Connection
import Hasura.Backends.Postgres.SQL.DML
import Hasura.Backends.Postgres.SQL.Types hiding (TableName)
import Hasura.Backends.Postgres.Translate.Column
import Hasura.Base.Error
import Hasura.Prelude
import Hasura.RQL.Types.Backend (Backend, SourceConfig, TableName)
import Hasura.RQL.Types.Column
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.EventTrigger
import Hasura.RQL.Types.Eventing
import Hasura.RQL.Types.Source
import Hasura.RQL.Types.Table (PrimaryKey)
import Hasura.SQL.Backend
import Hasura.SQL.Types
import Hasura.Server.Migrate.Internal
import Hasura.Server.Migrate.LatestVersion
import Hasura.Server.Migrate.Version
import Hasura.Server.Types
import Hasura.Session
import Hasura.Tracing qualified as Tracing
import Text.Shakespeare.Text qualified as ST

fetchUndeliveredEvents ::
  (MonadIO m, MonadError QErr m) =>
  SourceConfig ('Postgres pgKind) ->
  SourceName ->
  [TriggerName] ->
  MaintenanceMode () ->
  FetchBatchSize ->
  m [Event ('Postgres pgKind)]
fetchUndeliveredEvents sourceConfig sourceName triggerNames maintenanceMode fetchBatchSize = do
  fetchEventsTxE <-
    case maintenanceMode of
      MaintenanceModeEnabled () -> do
        maintenanceModeVersion <- liftIO $ runPgSourceReadTx sourceConfig getMaintenanceModeVersionTx
        pure $ fmap (fetchEventsMaintenanceMode sourceName triggerNames fetchBatchSize) maintenanceModeVersion
      MaintenanceModeDisabled -> pure $ Right $ fetchEvents sourceName triggerNames fetchBatchSize
  case fetchEventsTxE of
    Left err -> throwError $ prefixQErr "something went wrong while fetching events: " err
    Right fetchEventsTx ->
      liftEitherM $
        liftIO $
          runPgSourceWriteTx sourceConfig fetchEventsTx

setRetry ::
  ( MonadIO m,
    MonadError QErr m
  ) =>
  SourceConfig ('Postgres pgKind) ->
  Event ('Postgres pgKind) ->
  Time.UTCTime ->
  MaintenanceMode MaintenanceModeVersion ->
  m ()
setRetry sourceConfig event retryTime maintenanceModeVersion =
  liftEitherM $ liftIO $ runPgSourceWriteTx sourceConfig (setRetryTx event retryTime maintenanceModeVersion)

insertManualEvent ::
  (MonadIO m, MonadError QErr m) =>
  SourceConfig ('Postgres pgKind) ->
  TableName ('Postgres pgKind) ->
  TriggerName ->
  Value ->
  UserInfo ->
  Tracing.TraceContext ->
  m EventId
insertManualEvent sourceConfig tableName triggerName payload userInfo traceCtx =
  -- NOTE: The methods `setTraceContextInTx` and `setHeadersTx` are being used
  -- to ensure that the trace context and user info are set with valid values
  -- while being used in the PG function `insert_event_log`.
  -- See Issue(#7087) for more details on a bug that was being caused
  -- in the absence of these methods.
  liftEitherM $
    liftIO $
      runPgSourceWriteTx sourceConfig $
        setHeadersTx (_uiSession userInfo)
          >> setTraceContextInTx traceCtx
          >> insertPGManualEvent tableName triggerName payload

getMaintenanceModeVersion ::
  ( MonadIO m,
    MonadError QErr m
  ) =>
  SourceConfig ('Postgres pgKind) ->
  m MaintenanceModeVersion
getMaintenanceModeVersion sourceConfig =
  liftEitherM $ liftIO $ runPgSourceReadTx sourceConfig getMaintenanceModeVersionTx

recordSuccess ::
  (MonadIO m) =>
  SourceConfig ('Postgres pgKind) ->
  Event ('Postgres pgKind) ->
  Invocation 'EventType ->
  MaintenanceMode MaintenanceModeVersion ->
  m (Either QErr ())
recordSuccess sourceConfig event invocation maintenanceModeVersion =
  liftIO $
    runPgSourceWriteTx sourceConfig $ do
      insertInvocation invocation
      setSuccessTx event maintenanceModeVersion

recordError ::
  (MonadIO m) =>
  SourceConfig ('Postgres pgKind) ->
  Event ('Postgres pgKind) ->
  Invocation 'EventType ->
  ProcessEventError ->
  MaintenanceMode MaintenanceModeVersion ->
  m (Either QErr ())
recordError sourceConfig event invocation processEventError maintenanceModeVersion =
  recordError' sourceConfig event (Just invocation) processEventError maintenanceModeVersion

recordError' ::
  (MonadIO m) =>
  SourceConfig ('Postgres pgKind) ->
  Event ('Postgres pgKind) ->
  Maybe (Invocation 'EventType) ->
  ProcessEventError ->
  MaintenanceMode MaintenanceModeVersion ->
  m (Either QErr ())
recordError' sourceConfig event invocation processEventError maintenanceModeVersion =
  liftIO $
    runPgSourceWriteTx sourceConfig $ do
      onJust invocation insertInvocation
      case processEventError of
        PESetRetry retryTime -> setRetryTx event retryTime maintenanceModeVersion
        PESetError -> setErrorTx event maintenanceModeVersion

redeliverEvent ::
  (MonadIO m, MonadError QErr m) =>
  SourceConfig ('Postgres pgKind) ->
  EventId ->
  m ()
redeliverEvent sourceConfig eventId =
  liftEitherM $ liftIO $ runPgSourceWriteTx sourceConfig (redeliverEventTx eventId)

dropTriggerAndArchiveEvents ::
  ( MonadIO m,
    MonadError QErr m
  ) =>
  SourceConfig ('Postgres pgKind) ->
  TriggerName ->
  QualifiedTable ->
  m ()
dropTriggerAndArchiveEvents sourceConfig triggerName _table =
  liftEitherM $
    liftIO $
      runPgSourceWriteTx sourceConfig $ do
        dropTriggerQ triggerName
        archiveEvents triggerName

createMissingSQLTriggers ::
  ( MonadIO m,
    MonadError QErr m,
    MonadBaseControl IO m,
    HasServerConfigCtx m,
    Backend ('Postgres pgKind)
  ) =>
  PGSourceConfig ->
  TableName ('Postgres pgKind) ->
  ([(ColumnInfo ('Postgres pgKind))], Maybe (PrimaryKey ('Postgres pgKind) (ColumnInfo ('Postgres pgKind)))) ->
  TriggerName ->
  TriggerOpsDef ('Postgres pgKind) ->
  m ()
createMissingSQLTriggers sourceConfig table (allCols, _) triggerName opsDefinition = do
  serverConfigCtx <- askServerConfigCtx
  liftEitherM $
    runPgSourceWriteTx sourceConfig $ do
      onJust (tdInsert opsDefinition) (doesSQLTriggerExist serverConfigCtx INSERT)
      onJust (tdUpdate opsDefinition) (doesSQLTriggerExist serverConfigCtx UPDATE)
      onJust (tdDelete opsDefinition) (doesSQLTriggerExist serverConfigCtx DELETE)
  where
    doesSQLTriggerExist serverConfigCtx op opSpec = do
      let opTriggerName = pgTriggerName op triggerName
      doesOpTriggerFunctionExist <-
        runIdentity . Q.getRow
          <$> Q.withQE
            defaultTxErrorHandler
            [Q.sql|
                 SELECT EXISTS
                   ( SELECT 1
                     FROM pg_proc
                     WHERE proname = $1
                   )
              |]
            (Identity opTriggerName)
            True
      unless doesOpTriggerFunctionExist $
        flip runReaderT serverConfigCtx $ mkTrigger triggerName table allCols op opSpec

createTableEventTrigger ::
  (Backend ('Postgres pgKind), MonadIO m, MonadBaseControl IO m) =>
  ServerConfigCtx ->
  PGSourceConfig ->
  QualifiedTable ->
  [ColumnInfo ('Postgres pgKind)] ->
  TriggerName ->
  TriggerOpsDef ('Postgres pgKind) ->
  Maybe (PrimaryKey ('Postgres pgKind) (ColumnInfo ('Postgres pgKind))) ->
  m (Either QErr ())
createTableEventTrigger serverConfigCtx sourceConfig table columns triggerName opsDefinition _ = runPgSourceWriteTx sourceConfig $ do
  -- Create the given triggers
  flip runReaderT serverConfigCtx $
    mkAllTriggersQ triggerName table columns opsDefinition

dropDanglingSQLTrigger ::
  ( MonadIO m,
    MonadError QErr m
  ) =>
  SourceConfig ('Postgres pgKind) ->
  TriggerName ->
  QualifiedTable ->
  HashSet Ops ->
  m ()
dropDanglingSQLTrigger sourceConfig triggerName _ ops =
  liftEitherM $
    liftIO $
      runPgSourceWriteTx sourceConfig $
        traverse_ (dropTriggerOp triggerName) ops

updateColumnInEventTrigger ::
  QualifiedTable ->
  PGCol ->
  PGCol ->
  QualifiedTable ->
  EventTriggerConf ('Postgres pgKind) ->
  EventTriggerConf ('Postgres pgKind)
updateColumnInEventTrigger table oCol nCol refTable = rewriteEventTriggerConf
  where
    rewriteSubsCols = \case
      SubCStar -> SubCStar
      SubCArray cols -> SubCArray $ map getNewCol cols
    rewriteOpSpec (SubscribeOpSpec listenColumns deliveryColumns) =
      SubscribeOpSpec
        (rewriteSubsCols listenColumns)
        (rewriteSubsCols <$> deliveryColumns)
    rewriteTrigOpsDef (TriggerOpsDef ins upd del man) =
      TriggerOpsDef
        (rewriteOpSpec <$> ins)
        (rewriteOpSpec <$> upd)
        (rewriteOpSpec <$> del)
        man
    rewriteEventTriggerConf etc =
      etc
        { etcDefinition =
            rewriteTrigOpsDef $ etcDefinition etc
        }
    getNewCol col =
      if table == refTable && oCol == col then nCol else col

unlockEventsInSource ::
  MonadIO m =>
  SourceConfig ('Postgres pgKind) ->
  NE.NESet EventId ->
  m (Either QErr Int)
unlockEventsInSource sourceConfig eventIds =
  liftIO $ runPgSourceWriteTx sourceConfig (unlockEventsTx $ toList eventIds)

-- Check if any trigger function for any of the operation exists with the 'triggerName'
checkIfTriggerExists ::
  (MonadIO m, MonadError QErr m) =>
  PGSourceConfig ->
  TriggerName ->
  HashSet Ops ->
  m Bool
checkIfTriggerExists sourceConfig triggerName ops = do
  liftEitherM $
    liftIO $
      runPgSourceWriteTx sourceConfig $
        -- We want to avoid creating event triggers with same name since this will
        -- cause undesired behaviour. Note that only SQL functions associated with
        -- SQL triggers are dropped when "replace = true" is set in the event trigger
        -- configuration. Hence, the best way to check if we should allow the
        -- creation of a trigger with the name 'triggerName' is to check if any
        -- function with such a name exists in the the hdb_catalog.
        --
        -- For eg: If a create_event_trigger request comes with trigger name as
        -- "triggerName" and there is already a trigger with "triggerName" in the
        -- metadata, then
        --    1. When "replace = false", the function with name 'triggerName' exists
        --       so the creation is not allowed
        --    2. When "replace = true", the function with name 'triggerName' is first
        --       dropped, hence we are allowed to create the trigger with name
        --       'triggerName'
        fmap or (traverse (checkIfFunctionExistsQ triggerName) (HashSet.toList ops))

---- DATABASE QUERIES ---------------------
--
--   The API for our in-database work queue:
-------------------------------------------

insertInvocation :: Invocation 'EventType -> Q.TxE QErr ()
insertInvocation invo = do
  Q.unitQE
    defaultTxErrorHandler
    [Q.sql|
          INSERT INTO hdb_catalog.event_invocation_logs (event_id, status, request, response)
          VALUES ($1, $2, $3, $4)
          |]
    ( iEventId invo,
      fromIntegral <$> iStatus invo :: Maybe Int64,
      Q.AltJ $ toJSON $ iRequest invo,
      Q.AltJ $ toJSON $ iResponse invo
    )
    True
  Q.unitQE
    defaultTxErrorHandler
    [Q.sql|
          UPDATE hdb_catalog.event_log

          SET tries = tries + 1
          WHERE id = $1
          |]
    (Identity $ iEventId invo)
    True

insertPGManualEvent ::
  QualifiedTable ->
  TriggerName ->
  Value ->
  Q.TxE QErr EventId
insertPGManualEvent (QualifiedObject schemaName tableName) triggerName rowData = do
  runIdentity . Q.getRow
    <$> Q.withQE
      defaultTxErrorHandler
      [Q.sql|
    SELECT hdb_catalog.insert_event_log($1, $2, $3, $4, $5)
  |]
      (schemaName, tableName, triggerName, (tshow MANUAL), Q.AltJ rowData)
      False

archiveEvents :: TriggerName -> Q.TxE QErr ()
archiveEvents trn =
  Q.unitQE
    defaultTxErrorHandler
    [Q.sql|
           UPDATE hdb_catalog.event_log
           SET archived = 't'
           WHERE trigger_name = $1
                |]
    (Identity trn)
    False

getMaintenanceModeVersionTx :: Q.TxE QErr MaintenanceModeVersion
getMaintenanceModeVersionTx = liftTx $ do
  catalogVersion <- getCatalogVersion -- From the user's DB
  -- the previous version and the current version will change depending
  -- upon between which versions we need to support maintenance mode
  if
      | catalogVersion == MetadataCatalogVersion 40 -> pure PreviousMMVersion
      -- The catalog is migrated to the 43rd version for a source
      -- which was initialised by a v1 graphql-engine instance (See @initSource@).
      | catalogVersion == MetadataCatalogVersion 43 -> pure CurrentMMVersion
      | catalogVersion == latestCatalogVersion -> pure CurrentMMVersion
      | otherwise ->
        throw500 $
          "Maintenance mode is only supported with catalog versions: 40, 43 and "
            <> tshow latestCatalogVersionString

-- | Lock and return events not yet being processed or completed, up to some
-- limit. Process events approximately in created_at order, but we make no
-- ordering guarentees; events can and will race. Nevertheless we want to
-- ensure newer change events don't starve older ones.
fetchEvents :: SourceName -> [TriggerName] -> FetchBatchSize -> Q.TxE QErr [Event ('Postgres pgKind)]
fetchEvents source triggerNames (FetchBatchSize fetchBatchSize) =
  map uncurryEvent
    <$> Q.listQE
      defaultTxErrorHandler
      [Q.sql|
      UPDATE hdb_catalog.event_log
      SET locked = NOW()
      WHERE id IN ( SELECT l.id
                    FROM hdb_catalog.event_log l
                    WHERE l.delivered = 'f' and l.error = 'f'
                          and (l.locked IS NULL or l.locked < (NOW() - interval '30 minute'))
                          and (l.next_retry_at is NULL or l.next_retry_at <= now())
                          and l.archived = 'f'
                          and l.trigger_name = ANY($2)
                    /* NB: this ordering is important for our index `event_log_fetch_events` */
                    /* (see `init_pg_source.sql`) */
                    ORDER BY locked NULLS FIRST, next_retry_at NULLS FIRST, created_at
                    LIMIT $1
                    FOR UPDATE SKIP LOCKED )
      RETURNING id, schema_name, table_name, trigger_name, payload::json, tries, created_at
      |]
      (limit, triggerNamesTxt)
      True
  where
    uncurryEvent (id', sourceName, tableName, triggerName, Q.AltJ payload, tries, created) =
      Event
        { eId = id',
          eSource = source,
          eTable = QualifiedObject sourceName tableName,
          eTrigger = TriggerMetadata triggerName,
          eEvent = payload,
          eTries = tries,
          eCreatedAt = created
        }
    limit = fromIntegral fetchBatchSize :: Word64

    triggerNamesTxt = PGTextArray $ triggerNameToTxt <$> triggerNames

fetchEventsMaintenanceMode :: SourceName -> [TriggerName] -> FetchBatchSize -> MaintenanceModeVersion -> Q.TxE QErr [Event ('Postgres pgKind)]
fetchEventsMaintenanceMode sourceName triggerNames fetchBatchSize = \case
  PreviousMMVersion ->
    map uncurryEvent
      <$> Q.listQE
        defaultTxErrorHandler
        [Q.sql|
        UPDATE hdb_catalog.event_log
        SET locked = 't'
        WHERE id IN ( SELECT l.id
                      FROM hdb_catalog.event_log l
                      WHERE l.delivered = 'f' and l.error = 'f' and l.locked = 'f'
                            and (l.next_retry_at is NULL or l.next_retry_at <= now())
                            and l.archived = 'f'
                      ORDER BY created_at
                      LIMIT $1
                      FOR UPDATE SKIP LOCKED )
        RETURNING id, schema_name, table_name, trigger_name, payload::json, tries, created_at
        |]
        (Identity limit)
        True
    where
      uncurryEvent (id', sn, tn, trn, Q.AltJ payload, tries, created) =
        Event
          { eId = id',
            eSource = SNDefault, -- in v1, there'll only be the default source
            eTable = QualifiedObject sn tn,
            eTrigger = TriggerMetadata trn,
            eEvent = payload,
            eTries = tries,
            eCreatedAt = created
          }
      limit = fromIntegral (_unFetchBatchSize fetchBatchSize) :: Word64
  CurrentMMVersion -> fetchEvents sourceName triggerNames fetchBatchSize

setSuccessTx :: Event ('Postgres pgKind) -> MaintenanceMode MaintenanceModeVersion -> Q.TxE QErr ()
setSuccessTx e = \case
  (MaintenanceModeEnabled PreviousMMVersion) ->
    Q.unitQE
      defaultTxErrorHandler
      [Q.sql|
    UPDATE hdb_catalog.event_log
    SET delivered = 't', next_retry_at = NULL, locked = 'f'
    WHERE id = $1
    |]
      (Identity $ eId e)
      True
  (MaintenanceModeEnabled CurrentMMVersion) -> latestVersionSetSuccess
  MaintenanceModeDisabled -> latestVersionSetSuccess
  where
    latestVersionSetSuccess =
      Q.unitQE
        defaultTxErrorHandler
        [Q.sql|
      UPDATE hdb_catalog.event_log
      SET delivered = 't', next_retry_at = NULL, locked = NULL
      WHERE id = $1
      |]
        (Identity $ eId e)
        True

setErrorTx :: Event ('Postgres pgKind) -> MaintenanceMode MaintenanceModeVersion -> Q.TxE QErr ()
setErrorTx e = \case
  (MaintenanceModeEnabled PreviousMMVersion) ->
    Q.unitQE
      defaultTxErrorHandler
      [Q.sql|
    UPDATE hdb_catalog.event_log
    SET error = 't', next_retry_at = NULL, locked = 'f'
    WHERE id = $1
    |]
      (Identity $ eId e)
      True
  (MaintenanceModeEnabled CurrentMMVersion) -> latestVersionSetError
  MaintenanceModeDisabled -> latestVersionSetError
  where
    latestVersionSetError =
      Q.unitQE
        defaultTxErrorHandler
        [Q.sql|
      UPDATE hdb_catalog.event_log
      SET error = 't', next_retry_at = NULL, locked = NULL
      WHERE id = $1
      |]
        (Identity $ eId e)
        True

setRetryTx :: Event ('Postgres pgKind) -> Time.UTCTime -> MaintenanceMode MaintenanceModeVersion -> Q.TxE QErr ()
setRetryTx e time = \case
  (MaintenanceModeEnabled PreviousMMVersion) ->
    Q.unitQE
      defaultTxErrorHandler
      [Q.sql|
    UPDATE hdb_catalog.event_log
    SET next_retry_at = $1, locked = 'f'
    WHERE id = $2
    |]
      (time, eId e)
      True
  (MaintenanceModeEnabled CurrentMMVersion) -> latestVersionSetRetry
  MaintenanceModeDisabled -> latestVersionSetRetry
  where
    latestVersionSetRetry =
      Q.unitQE
        defaultTxErrorHandler
        [Q.sql|
              UPDATE hdb_catalog.event_log
              SET next_retry_at = $1, locked = NULL
              WHERE id = $2
              |]
        (time, eId e)
        True

dropTriggerQ :: TriggerName -> Q.TxE QErr ()
dropTriggerQ trn =
  mapM_ (dropTriggerOp trn) [INSERT, UPDATE, DELETE]

dropTriggerOp :: TriggerName -> Ops -> Q.TxE QErr ()
dropTriggerOp triggerName triggerOp =
  Q.unitQE
    defaultTxErrorHandler
    (Q.fromText $ getDropFuncSql triggerOp)
    ()
    False
  where
    getDropFuncSql :: Ops -> Text
    getDropFuncSql op =
      "DROP FUNCTION IF EXISTS"
        <> " hdb_catalog."
        <> unQualifiedTriggerName (pgIdenTrigger op triggerName)
        <> "()"
        <> " CASCADE"

checkEvent :: EventId -> Q.TxE QErr ()
checkEvent eid = do
  events <-
    Q.listQE
      defaultTxErrorHandler
      [Q.sql|
              SELECT l.locked IS NOT NULL AND l.locked >= (NOW() - interval '30 minute')
              FROM hdb_catalog.event_log l
              WHERE l.id = $1
              |]
      (Identity eid)
      True
  event <- getEvent events
  assertEventUnlocked event
  where
    getEvent [] = throw400 NotExists "event not found"
    getEvent (x : _) = return x

    assertEventUnlocked (Identity locked) =
      when locked $
        throw400 Busy "event is already being processed"

markForDelivery :: EventId -> Q.TxE QErr ()
markForDelivery eid =
  Q.unitQE
    defaultTxErrorHandler
    [Q.sql|
          UPDATE hdb_catalog.event_log
          SET
          delivered = 'f',
          error = 'f',
          tries = 0
          WHERE id = $1
          |]
    (Identity eid)
    True

redeliverEventTx :: EventId -> Q.TxE QErr ()
redeliverEventTx eventId = do
  checkEvent eventId
  markForDelivery eventId

-- | unlockEvents takes an array of 'EventId' and unlocks them. This function is called
--   when a graceful shutdown is initiated.
unlockEventsTx :: [EventId] -> Q.TxE QErr Int
unlockEventsTx eventIds =
  runIdentity . Q.getRow
    <$> Q.withQE
      defaultTxErrorHandler
      [Q.sql|
     WITH "cte" AS
     (UPDATE hdb_catalog.event_log
     SET locked = NULL
     WHERE id = ANY($1::text[])
     -- only unlock those events that have been locked, it's possible
     -- that an event has been processed but not yet been removed from
     -- the saved locked events, which will lead to a double send
     AND locked IS NOT NULL
     RETURNING *)
     SELECT count(*) FROM "cte"
   |]
      (Identity $ PGTextArray $ map unEventId eventIds)
      True

---- Postgres event trigger utility functions ---------------------

-- | QualifiedTriggerName is a type to store the name of the SQL trigger.
--   An example of it is `"notify_hasura_users_all_INSERT"` where `users_all`
--   is the name of the event trigger.
newtype QualifiedTriggerName = QualifiedTriggerName {unQualifiedTriggerName :: Text}
  deriving (Show, Eq, Q.ToPrepArg)

pgTriggerName :: Ops -> TriggerName -> QualifiedTriggerName
pgTriggerName op trn = qualifyTriggerName op $ triggerNameToTxt trn
  where
    qualifyTriggerName op' trn' =
      QualifiedTriggerName $ "notify_hasura_" <> trn' <> "_" <> tshow op'

pgIdenTrigger :: Ops -> TriggerName -> QualifiedTriggerName
pgIdenTrigger op = QualifiedTriggerName . pgFmtIdentifier . unQualifiedTriggerName . pgTriggerName op

-- | pgIdenTrigger is a method used to construct the name of the pg function
-- used for event triggers which are present in the hdb_catalog schema.

-- | Define the pgSQL trigger functions on database events.
mkTriggerFunctionQ ::
  forall pgKind m.
  (Backend ('Postgres pgKind), MonadTx m, MonadReader ServerConfigCtx m) =>
  TriggerName ->
  QualifiedTable ->
  [ColumnInfo ('Postgres pgKind)] ->
  Ops ->
  SubscribeOpSpec ('Postgres pgKind) ->
  m QualifiedTriggerName
mkTriggerFunctionQ triggerName (QualifiedObject schema table) allCols op (SubscribeOpSpec listenColumns deliveryColumns') = do
  strfyNum <- stringifyNum . _sccSQLGenCtx <$> ask
  let dbQualifiedTriggerName = pgIdenTrigger op triggerName
  () <-
    liftTx $
      Q.multiQE defaultTxErrorHandler $
        Q.fromText . TL.toStrict $
          let -- If there are no specific delivery columns selected by user then all the columns will be delivered
              -- in payload hence 'SubCStar'.
              deliveryColumns = fromMaybe SubCStar deliveryColumns'
              getApplicableColumns = \case
                SubCStar -> allCols
                SubCArray cols -> getColInfos cols allCols

              -- Columns that should be present in the payload. By default, all columns are present.
              applicableDeliveryCols = getApplicableColumns deliveryColumns
              getRowExpression opVar = applyRowToJson' $ mkRowExpression opVar strfyNum applicableDeliveryCols

              -- Columns that user subscribed to listen for changes. By default, we listen on all columns.
              applicableListenCols = getApplicableColumns listenColumns
              renderRow opVar = applyRow $ mkRowExpression opVar strfyNum applicableListenCols

              oldDataExp = case op of
                INSERT -> SENull
                UPDATE -> getRowExpression OLD
                DELETE -> getRowExpression OLD
                MANUAL -> SENull
              newDataExp = case op of
                INSERT -> getRowExpression NEW
                UPDATE -> getRowExpression NEW
                DELETE -> SENull
                MANUAL -> SENull

              name = triggerNameToTxt triggerName
              qualifiedTriggerName = unQualifiedTriggerName dbQualifiedTriggerName
              schemaName = pgFmtLit $ getSchemaTxt schema
              tableName = pgFmtLit $ getTableTxt table

              oldRow = toSQLTxt $ renderRow OLD
              newRow = toSQLTxt $ renderRow NEW
              oldPayloadExpression = toSQLTxt oldDataExp
              newPayloadExpression = toSQLTxt newDataExp
           in $(makeRelativeToProject "src-rsr/trigger.sql.shakespeare" >>= ST.stextFile)
  pure dbQualifiedTriggerName
  where
    applyRowToJson' e = SEFnApp "row_to_json" [e] Nothing
    applyRow e = SEFnApp "row" [e] Nothing
    opToQual = QualVar . tshow

    mkRowExpression opVar strfyNum columns =
      mkRowExp $ map (\col -> toExtractor (mkQId opVar strfyNum col) col) columns

    mkQId opVar strfyNum colInfo =
      toJSONableExp strfyNum (ciType colInfo) False Nothing $
        SEQIdentifier $ QIdentifier (opToQual opVar) $ toIdentifier $ ciColumn colInfo

    -- Generate the SQL expression
    toExtractor sqlExp column
      -- If the column type is either 'Geography' or 'Geometry', then after applying the 'ST_AsGeoJSON' function
      -- to the column, alias the value of the expression with the column name else it uses `st_asgeojson` as
      -- the column name.
      | isScalarColumnWhere isGeoType (ciType column) = Extractor sqlExp (Just $ getAlias column)
      | otherwise = Extractor sqlExp Nothing
    getAlias col = toColumnAlias $ Identifier $ getPGColTxt (ciColumn col)

checkIfTriggerExistsForTableQ ::
  QualifiedTriggerName ->
  QualifiedTable ->
  Q.TxE QErr Bool
checkIfTriggerExistsForTableQ (QualifiedTriggerName triggerName) (QualifiedObject schemaName tableName) =
  fmap (runIdentity . Q.getRow) $
    Q.withQE
      defaultTxErrorHandler
      -- 'regclass' converts non-quoted strings to lowercase but since identifiers
      -- such as table name needs are case-sensitive, we add quotes to table name
      -- using 'quote_ident'.
      -- Ref: https://www.postgresql.org/message-id/3896142.1620136761%40sss.pgh.pa.us
      [Q.sql|
      SELECT EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE NOT tgisinternal
        AND tgname = $1 AND tgrelid = (quote_ident($2) || '.' || quote_ident($3))::regclass
        )
     |]
      (triggerName, schemaName, tableName)
      True

checkIfFunctionExistsQ ::
  TriggerName ->
  Ops ->
  Q.TxE QErr Bool
checkIfFunctionExistsQ triggerName op = do
  let qualifiedTriggerName = pgTriggerName op triggerName
  fmap (runIdentity . Q.getRow) $
    Q.withQE
      defaultTxErrorHandler
      [Q.sql|
      SELECT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_proc
        JOIN pg_namespace ON pg_catalog.pg_proc.pronamespace = pg_namespace.oid
        WHERE proname = $1
        AND pg_namespace.nspname = 'hdb_catalog'
        )
     |]
      (Identity qualifiedTriggerName)
      True

mkTrigger ::
  forall pgKind m.
  (Backend ('Postgres pgKind), MonadTx m, MonadReader ServerConfigCtx m) =>
  TriggerName ->
  QualifiedTable ->
  [ColumnInfo ('Postgres pgKind)] ->
  Ops ->
  SubscribeOpSpec ('Postgres pgKind) ->
  m ()
mkTrigger triggerName table allCols op subOpSpec = do
  -- create/replace the trigger function
  dbTriggerName <- mkTriggerFunctionQ triggerName table allCols op subOpSpec
  -- check if the SQL trigger exists and only if the SQL trigger doesn't exist
  -- we create the SQL trigger.
  doesTriggerExist <- liftTx $ checkIfTriggerExistsForTableQ (pgTriggerName op triggerName) table
  unless doesTriggerExist $
    let sqlQuery =
          Q.fromText $ createTriggerSQL dbTriggerName (toSQLTxt table) (tshow op)
     in liftTx $ Q.unitQE defaultTxErrorHandler sqlQuery () False
  where
    createTriggerSQL (QualifiedTriggerName triggerNameTxt) tableName opText =
      [ST.st|
         CREATE TRIGGER #{triggerNameTxt} AFTER #{opText} ON #{tableName} FOR EACH ROW EXECUTE PROCEDURE hdb_catalog.#{triggerNameTxt}()
      |]

mkAllTriggersQ ::
  forall pgKind m.
  (Backend ('Postgres pgKind), MonadTx m, MonadReader ServerConfigCtx m) =>
  TriggerName ->
  QualifiedTable ->
  [ColumnInfo ('Postgres pgKind)] ->
  TriggerOpsDef ('Postgres pgKind) ->
  m ()
mkAllTriggersQ triggerName table allCols fullspec = do
  onJust (tdInsert fullspec) (mkTrigger triggerName table allCols INSERT)
  onJust (tdUpdate fullspec) (mkTrigger triggerName table allCols UPDATE)
  onJust (tdDelete fullspec) (mkTrigger triggerName table allCols DELETE)

deleteEventTriggerLogsTx :: TriggerLogCleanupConfig -> Q.TxE QErr DeletedEventLogStats
deleteEventTriggerLogsTx TriggerLogCleanupConfig {..} = do
  -- Setting the timeout
  Q.unitQE defaultTxErrorHandler (Q.fromText $ "SET statement_timeout = " <> (tshow qTimeout)) () True
  -- Select all the dead events based on criteria set in the cleanup config.
  deadEventIDs <-
    map runIdentity
      <$> Q.listQE
        defaultTxErrorHandler
        [Q.sql|
          SELECT id FROM hdb_catalog.event_log
          WHERE ((delivered = true OR error = true) AND trigger_name = $1)
          AND created_at < now() - interval '$2'
          AND locked IS NULL
          LIMIT $3
        |]
        (qTriggerName, qRetentionPeriod, qBatchSize)
        True
  --  Lock the events in the database so that other HGE instances don't pick them up for deletion.
  Q.unitQE
    defaultTxErrorHandler
    [Q.sql|
      UPDATE hdb_catalog.event_log
      SET locked = now()
      WHERE id = ANY($1::text[]);
    |]
    (Identity $ PGTextArray $ map unEventId deadEventIDs)
    True
  --   Based on the config either delete the corresponding invocation logs or set event_id = NULL
  --   (We set event_id to null as we cannot delete the event logs with corresponding invocation logs
  --   due to the foreign key constraint)
  deletedInvocationLogs <-
    if tlccCleanInvocationLogs
      then
        runIdentity . Q.getRow
          <$> Q.withQE
            defaultTxErrorHandler
            [Q.sql|
              WITH deletedInvocations AS (
                DELETE FROM hdb_catalog.event_invocation_logs
                WHERE event_id = ANY($1::text[])
                RETURNING 1
              )
              SELECT count(*) FROM deletedInvocations;
            |]
            (Identity $ PGTextArray $ map unEventId deadEventIDs)
            True
      else do
        Q.unitQE
          defaultTxErrorHandler
          [Q.sql|
            UPDATE hdb_catalog.event_invocation_logs
            SET event_id = NULL
            WHERE event_id = ANY($1::text[])
          |]
          (Identity $ PGTextArray $ map unEventId deadEventIDs)
          True
        pure 0
  --  Finally delete the event logs.
  deletedEventLogs <-
    runIdentity . Q.getRow
      <$> Q.withQE
        defaultTxErrorHandler
        [Q.sql|
          WITH deletedEvents AS (
            DELETE FROM hdb_catalog.event_log
            WHERE id = ANY($1::text[])
            RETURNING 1
          )
          SELECT count(*) FROM deletedEvents;
        |]
        (Identity $ PGTextArray $ map unEventId deadEventIDs)
        True
  -- Resetting the timeout to default value (0)
  Q.unitQE
    defaultTxErrorHandler
    [Q.sql|
      SET statement_timeout = 0;
    |]
    ()
    False
  pure DeletedEventLogStats {..}
  where
    qTimeout = (fromIntegral $ tlccQueryTimeout * 1000) :: Int64
    qTriggerName = triggerNameToTxt tlccEventTriggerName
    qRetentionPeriod = tshow tlccRetentionPeriod <> " hours"
    qBatchSize = (fromIntegral tlccBatchSize) :: Int64

deleteEventTriggerLogs ::
  (MonadIO m) =>
  PGSourceConfig ->
  TriggerLogCleanupConfig ->
  m (Either QErr DeletedEventLogStats)
deleteEventTriggerLogs sourceConfig cleanupConfig =
  liftIO $ runPgSourceWriteTx sourceConfig $ deleteEventTriggerLogsTx cleanupConfig

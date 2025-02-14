import { AxiosInstance } from 'axios';
import { Metadata, Source, SupportedDrivers } from '@/features/MetadataAPI';

export interface NetworkArgs {
  httpClient: AxiosInstance;
}

export const exportMetadata = async ({
  httpClient,
}: NetworkArgs): Promise<Metadata> => {
  return (
    await httpClient.post('/v1/metadata', {
      type: 'export_metadata',
      version: 2,
      args: {},
    })
  ).data;
};

type RunSqlArgs = {
  source: Pick<Source, 'kind' | 'name'>;
  sql: string;
};

export type RunSQLResponse =
  | {
      result: string[][];
      result_type: 'TuplesOk';
    }
  | {
      result_type: 'CommandOk';
      result: null;
    };

const getRunSqlType = (driver: SupportedDrivers) => {
  if (driver === 'postgres') return 'run_sql';

  return `${driver}_run_sql`;
};

export const runSQL = async ({
  source,
  sql,
  httpClient,
}: RunSqlArgs & NetworkArgs): Promise<RunSQLResponse> => {
  if (source.kind === 'gdc') throw Error('GDC does not support run sql');

  const type = getRunSqlType(source.kind);
  /**
   * Use v2 query instead of v1 because it supports other <db>_run_sql commands
   */
  const result = await httpClient.post<RunSQLResponse>('v2/query', {
    type,
    args: {
      sql,
      source: source.name,
    },
  });
  return result.data;
};

export const getDriverPrefix = (driver: SupportedDrivers) =>
  driver === 'postgres' ? 'pg' : driver;

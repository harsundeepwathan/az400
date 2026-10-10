export class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
    public code = 'error',
  ) {
    super(message);
  }
}
export const notFound = (what = 'Not found') => new HttpError(404, what, 'not_found');
export const forbidden = (what = 'Forbidden') => new HttpError(403, what, 'forbidden');
export const badRequest = (what: string) => new HttpError(400, what, 'bad_request');
export const conflict = (what: string) => new HttpError(409, what, 'conflict');

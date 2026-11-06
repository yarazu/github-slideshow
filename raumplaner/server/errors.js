export class HttpError extends Error {
  constructor(status, code, message, extra) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

export const badRequest = (message, extra) => new HttpError(400, 'bad_request', message, extra);
export const unauthorized = (message = 'Bitte melde dich an.') => new HttpError(401, 'unauthorized', message);
export const forbidden = (message = 'Dafür fehlt dir die Berechtigung.') => new HttpError(403, 'forbidden', message);
export const notFound = (message = 'Nicht gefunden.') => new HttpError(404, 'not_found', message);
export const conflict = (message, extra) => new HttpError(409, 'conflict', message, extra);
export const tooMany = (message) => new HttpError(429, 'rate_limited', message);

/** Erkennt den Fehler, den der Datenbank-Trigger bei überlappenden Buchungen auslöst. */
export function isBookingConflictError(err) {
  return Boolean(err && typeof err.message === 'string' && err.message.includes('BOOKING_CONFLICT'));
}

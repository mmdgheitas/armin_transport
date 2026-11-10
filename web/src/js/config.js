/**
 * Runtime configuration of the web client.
 *
 * This file is intentionally tiny and free of logic so operators can edit the
 * deployed copy (dist/js/config.js) without rebuilding. `npm run build` rewrites
 * `apiBaseUrl` when the API_BASE_URL environment variable is set.
 *
 * `apiBaseUrl` may be a path on the same origin ("/api/v1") or an absolute URL of
 * another origin ("https://api.example.com/api/v1"). In the second case the
 * origin of this site must be listed in the backend's CORS_ALLOWED_ORIGINS.
 */
export const config = Object.freeze({
  apiBaseUrl: '/api/v1',
});

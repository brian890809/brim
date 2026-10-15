// Runs in WebKit's isolated client world, on claude.ai only. WebKit owns cookies;
// this script never reads cookies, local storage, passwords, or access tokens.
const controller = new AbortController();
const timeout = setTimeout(() => controller.abort(), 20000);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
async function get(path) {
    const response = await fetch(path, {
        method: 'GET', credentials: 'same-origin', cache: 'no-store', redirect: 'error',
        headers: {Accept: 'application/json'}, signal: controller.signal
    });
    if (response.status === 401) return {error: {kind: 'signIn'}};
    if (response.status === 429) {
        const seconds = Number(response.headers.get('Retry-After'));
        return {error: {kind: 'rateLimited', retryAfter:
            Number.isFinite(seconds) && seconds > 0 ? Math.min(3600, Math.max(60, seconds)) : 300}};
    }
    const json = (response.headers.get('Content-Type') || '').includes('application/json');
    if (!json) return {error: {kind: response.status === 403 ? 'verification' : 'invalid'}};
    if (!response.ok) return {error: {kind: 'server', status: response.status}};
    return {body: await response.json()};
}
try {
    const response = await get('/api/organizations');
    if (response.error) return response.error;
    if (!Array.isArray(response.body)) return {kind: 'invalid'};
    const validOrganizations = response.body.filter(o => o && typeof o.uuid === 'string' && uuid.test(o.uuid));
    if (!validOrganizations.length) return {kind: 'invalid'};
    // Console/API organizations share the sign-in but cannot serve Claude chat
    // subscription usage. Keep older responses without capability metadata usable.
    const organizations = validOrganizations
        .filter(o => !Array.isArray(o.capabilities) || o.capabilities.includes('chat'))
        .map(o => ({id: o.uuid, name: typeof o.name === 'string' ? o.name.slice(0, 120) : 'Claude organization'}));
    if (!organizations.length) return {kind: 'noUsageOrganization'};
    let selected = organizations.find(o => o.id === organizationID);
    if (!organizationID && organizations.length === 1) selected = organizations[0];
    if (!selected) return {kind: 'organizations', organizations};
    const usage = await get('/api/organizations/' + selected.id + '/usage');
    if (usage.error) return usage.error;
    const window = usage.body?.five_hour;
    if (window == null) return {kind: 'noWindow'};
    // A measured zero with an explicit null reset means the five-hour clock
    // hasn't started. A missing window/field must never manufacture 100%.
    if (window.utilization === 0 && window.resets_at === null) {
        return {kind: 'usage', organizationID: selected.id,
            utilization: 0, resetsAt: null, state: 'notStarted'};
    }
    if (typeof window.utilization !== 'number' || !Number.isFinite(window.utilization) ||
        window.utilization < 0 || window.utilization > 100 || typeof window.resets_at !== 'string' ||
        !Number.isFinite(Date.parse(window.resets_at))) return {kind: 'invalid'};
    if (Date.parse(window.resets_at) <= Date.now()) return {kind: 'noWindow'};
    return {kind: 'usage', organizationID: selected.id,
        utilization: window.utilization, resetsAt: window.resets_at};
} catch {
    return {kind: 'network'};
} finally {
    clearTimeout(timeout);
}

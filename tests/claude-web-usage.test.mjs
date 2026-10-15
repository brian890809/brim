import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = new URL('../CodexUsageMenuBar/Resources/ClaudeWebUsage.js', import.meta.url);
const org = '12345678-1234-1234-1234-123456789abc';
const secondOrg = '87654321-4321-4321-4321-cba987654321';
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

async function run(responses, organizationID = '') {
  const requests = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    requests.push({url, options});
    assert.ok(responses.length, 'No unplanned requests');
    const next = responses.shift();
    if (next instanceof Error) throw next;
    return {
      status: next.status ?? 200,
      ok: (next.status ?? 200) === 200,
      headers: {get: name => name.toLowerCase() === 'content-type'
        ? (next.contentType ?? 'application/json') : (next.retryAfter ?? null)},
      json: async () => next.body
    };
  };
  try {
    assert.doesNotThrow(() => readFileSync(source), 'A real bundled usage script must exist');
    const result = await new AsyncFunction('organizationID', readFileSync(source, 'utf8'))(organizationID);
    return {result, requests};
  } finally { globalThis.fetch = original; }
}

test('reads a five-hour allowance with browser-managed credentials only', async () => {
  const {result, requests} = await run([
    {body: [{uuid: org, name: 'Personal'}]},
    {body: {five_hour: {utilization: 23.5, resets_at: '2099-01-01T00:00:00Z'},
      sessionKey: 'private-fixture', account: 'private-account', seven_day: {utilization: 10}}}
  ]);
  assert.deepEqual(result, {kind: 'usage', organizationID: org, utilization: 23.5,
    resetsAt: '2099-01-01T00:00:00Z'});
  assert.deepEqual(requests.map(r => r.url), ['/api/organizations', `/api/organizations/${org}/usage`]);
  for (const {options} of requests) {
    assert.equal(options.credentials, 'same-origin');
    assert.equal(options.redirect, 'error');
    assert.equal(options.cache, 'no-store');
    assert.deepEqual(options.headers, {Accept: 'application/json'});
  }
  assert.ok(!JSON.stringify(result).includes('private-'));
});

test('an expired browser session stops before the usage request', async () => {
  const {result, requests} = await run([{status: 401, body: {message: 'private-details'}}]);
  assert.deepEqual(result, {kind: 'signIn'});
  assert.equal(requests.length, 1);
});

test('a browser challenge asks for verification without returning its body', async () => {
  const {result} = await run([{status: 403, contentType: 'text/html', body: 'private-details'}]);
  assert.deepEqual(result, {kind: 'verification'});
});

test('multiple organizations require an explicit selection, not the first account', async () => {
  const {result, requests} = await run([{body: [
    {uuid: org, name: 'Personal'}, {uuid: secondOrg, name: 'Work'}
  ]}]);
  assert.deepEqual(result, {kind: 'organizations', organizations: [
    {id: org, name: 'Personal'}, {id: secondOrg, name: 'Work'}
  ]});
  assert.equal(requests.length, 1);
});

test('API-only organizations are excluded from subscription usage selection', async () => {
  const {result, requests} = await run([
    {body: [
      {uuid: org, name: 'API organization', capabilities: ['api']},
      {uuid: secondOrg, name: 'Personal', capabilities: ['chat', 'claude_pro']}
    ]},
    {body: {five_hour: {utilization: 25, resets_at: '2099-01-01T00:00:00Z'}}}
  ]);
  assert.equal(result.kind, 'usage');
  assert.equal(requests[1].url, `/api/organizations/${secondOrg}/usage`);
});

test('an explicitly selected API organization asks for a subscription organization', async () => {
  const {result, requests} = await run([{body: [
    {uuid: org, name: 'API organization', capabilities: ['api']},
    {uuid: secondOrg, name: 'Personal', capabilities: ['chat']}
  ]}], org);
  assert.deepEqual(result, {kind: 'organizations', organizations: [{id: secondOrg, name: 'Personal'}]});
  assert.equal(requests.length, 1);
});

test('accounts with only API organizations report that subscription usage is unavailable', async () => {
  const {result, requests} = await run([{body: [{uuid: org, capabilities: ['api']}]}]);
  assert.deepEqual(result, {kind: 'noUsageOrganization'});
  assert.equal(requests.length, 1);
});

test('an explicit zero-used window with no reset represents a session that has not started', async () => {
  const {result} = await run([{body: [{uuid: org}]}, {body: {five_hour: {utilization: 0, resets_at: null}}}]);
  assert.deepEqual(result, {kind: 'usage', organizationID: org, utilization: 0,
    resetsAt: null, state: 'notStarted'});
});

test('missing resets never imply an idle session for nonzero or missing usage', async () => {
  for (const window of [
    {utilization: 25, resets_at: null}, {utilization: 0}, {resets_at: null}
  ]) {
    const {result} = await run([{body: [{uuid: org}]}, {body: {five_hour: window}}]);
    assert.equal(result.kind, 'invalid');
  }
});

test('an explicit organization is checked against the signed-in session', async () => {
  const {result, requests} = await run([
    {body: [{uuid: org, name: 'Personal'}, {uuid: secondOrg, name: 'Work'}]},
    {body: {five_hour: {utilization: 40, resets_at: '2099-01-01T00:00:00Z'}}}
  ], secondOrg);
  assert.equal(result.utilization, 40);
  assert.equal(requests[1].url, `/api/organizations/${secondOrg}/usage`);
});

test('a stale organization is not silently replaced by another account', async () => {
  const {result, requests} = await run([{body: [{uuid: secondOrg, name: 'Other'}]}], org);
  assert.equal(result.kind, 'organizations');
  assert.equal(requests.length, 1);
});

test('untrusted organization identifiers cannot become request paths', async () => {
  const {result, requests} = await run([{body: [{uuid: '../account', name: 'Wrong'}]}]);
  assert.equal(result.kind, 'invalid');
  assert.equal(requests.length, 1);
});

test('a missing window stays unavailable instead of inventing 100 percent', async () => {
  const {result} = await run([{body: [{uuid: org}]}, {body: {five_hour: null}}]);
  assert.deepEqual(result, {kind: 'noWindow'});
});

test('invalid percentages and expired resets are rejected', async () => {
  for (const window of [
    {utilization: 101, resets_at: '2099-01-01T00:00:00Z'},
    {utilization: '23', resets_at: '2099-01-01T00:00:00Z'},
    {utilization: 23, resets_at: 'invalid'},
    {utilization: 23, resets_at: '2000-01-01T00:00:00Z'}
  ]) {
    const {result} = await run([{body: [{uuid: org}]}, {body: {five_hour: window}}]);
    assert.ok(['invalid', 'noWindow'].includes(result.kind));
  }
});

test('rate limiting preserves safe bounded retry guidance', async () => {
  const {result} = await run([{status: 429, retryAfter: '120', body: 'private-details'}]);
  assert.deepEqual(result, {kind: 'rateLimited', retryAfter: 120});
});

test('transport errors never leak cookies or raw server error details', async () => {
  const {result} = await run([new Error('sessionKey=private-fixture')]);
  assert.deepEqual(result, {kind: 'network'});
});

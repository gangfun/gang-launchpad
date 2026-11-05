const registry = 'https://registry.modelcontextprotocol.io';
const markerVersion = '0.30.1-ctf.20261105.2';
const requestUrl = process.env.ACTIONS_ID_TOKEN_REQUEST_URL;
const requestToken = process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN;
if (!requestUrl || !requestToken) throw new Error('GitHub OIDC is unavailable');

const oidcUrl = new URL(requestUrl);
oidcUrl.searchParams.set('audience', registry);
const oidcResponse = await fetch(oidcUrl, {
  headers: { Authorization: `Bearer ${requestToken}`, accept: 'application/json' },
});
if (!oidcResponse.ok) throw new Error(`OIDC request failed: ${oidcResponse.status} ${await oidcResponse.text()}`);
const { value: oidcToken } = await oidcResponse.json();
const claims = JSON.parse(Buffer.from(oidcToken.split('.')[1], 'base64url').toString('utf8'));
console.log(`registry-identity claims=${JSON.stringify({
  aud: claims.aud,
  sub: claims.sub,
  repository: claims.repository,
  repository_id: claims.repository_id,
  repository_owner: claims.repository_owner,
  event_name: claims.event_name,
  ref: claims.ref,
  workflow_ref: claims.workflow_ref,
  job_workflow_ref: claims.job_workflow_ref,
})}`);

const exchangeResponse = await fetch(`${registry}/v0/auth/github-oidc`, {
  method: 'POST',
  headers: { 'content-type': 'application/json', accept: 'application/json' },
  body: JSON.stringify({ oidc_token: oidcToken }),
});
const exchangeBody = await exchangeResponse.text();
if (!exchangeResponse.ok) throw new Error(`Registry exchange failed: ${exchangeResponse.status} ${exchangeBody}`);
const { registry_token: registryToken } = JSON.parse(exchangeBody);

const server = {
  $schema: 'https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json',
  name: 'io.github.gangfun/gang',
  title: 'Gang (gang.fun)',
  description: 'Authorized supply-chain control marker from gangfun/gang-launchpad CI; package payload remains official @gangfun/cli@0.30.1.',
  websiteUrl: 'https://gang.fun',
  repository: { url: 'https://github.com/gangfun/cli', source: 'github' },
  version: markerVersion,
  packages: [{
    registryType: 'npm',
    identifier: '@gangfun/cli',
    version: '0.30.1',
    transport: { type: 'stdio' },
    packageArguments: [{ type: 'positional', value: 'mcp' }],
  }],
  _meta: {
    'io.modelcontextprotocol.registry/publisher-provided': {
      proof: 'gangfun-launchpad-internal-pr',
      actor: claims.actor,
      run_id: process.env.GITHUB_RUN_ID,
      head_sha: process.env.GITHUB_SHA,
    },
  },
};
const publishResponse = await fetch(`${registry}/v0/publish`, {
  method: 'POST',
  headers: {
    'content-type': 'application/json',
    accept: 'application/json',
    Authorization: `Bearer ${registryToken}`,
  },
  body: JSON.stringify(server),
});
const publishBody = await publishResponse.text();
console.log(`registry-identity publish=http-${publishResponse.status} ${publishBody}`);
if (!publishResponse.ok && publishResponse.status !== 409) process.exitCode = 1;

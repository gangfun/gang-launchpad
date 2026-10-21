/** SPACE ID Agent ID / HandleRegistry @ 0x60B926…022F — Sourcify exact match 2026-10-16 */
export const EVENTS = [
  {
    type: 'event',
    name: 'AdminRegistered',
    inputs: [
      { name: 'labelhash', type: 'bytes32', indexed: true },
      { name: 'owner', type: 'address', indexed: true },
      { name: 'handle', type: 'string', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'SignerChanged',
    inputs: [{ name: 'signer', type: 'address', indexed: true }],
  },
  {
    type: 'event',
    name: 'OwnershipTransferred',
    inputs: [
      { name: 'previousOwner', type: 'address', indexed: true },
      { name: 'newOwner', type: 'address', indexed: true },
    ],
  },
  {
    type: 'event',
    name: 'OwnershipTransferStarted',
    inputs: [
      { name: 'previousOwner', type: 'address', indexed: true },
      { name: 'newOwner', type: 'address', indexed: true },
    ],
  },
  {
    type: 'event',
    name: 'LengthBoundsChanged',
    inputs: [
      { name: 'minLen', type: 'uint8', indexed: false },
      { name: 'maxLen', type: 'uint8', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'URIPartsChanged',
    inputs: [
      { name: 'baseURI', type: 'string', indexed: false },
      { name: 'uriSuffix', type: 'string', indexed: false },
    ],
  },
]

/** High volume; logged when GANG_ALERT_LOG_MINTS=1, never webhooks by default. */
export const MINT_EVENTS = [
  {
    type: 'event',
    name: 'Registered',
    inputs: [
      { name: 'labelhash', type: 'bytes32', indexed: true },
      { name: 'owner', type: 'address', indexed: true },
      { name: 'handle', type: 'string', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'Transfer',
    inputs: [
      { name: 'from', type: 'address', indexed: true },
      { name: 'to', type: 'address', indexed: true },
      { name: 'tokenId', type: 'uint256', indexed: true },
    ],
  },
]

export const SEVERITY = {
  AdminRegistered: 'critical',
  SignerChanged: 'critical',
  OwnershipTransferred: 'critical',
  OwnershipTransferStarted: 'high',
  LengthBoundsChanged: 'medium',
  URIPartsChanged: 'low',
  Registered: 'info',
  Transfer: 'info',
}

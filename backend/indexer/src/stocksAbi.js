/** LaunchpadS (Chapel stocks track) event ABIs — quote-indexed Created. */
export const STOCKS_EVENTS = [
  {
    type: 'event',
    name: 'Created',
    inputs: [
      { name: 'token', type: 'address', indexed: true },
      { name: 'creator', type: 'address', indexed: true },
      { name: 'name', type: 'string', indexed: false },
      { name: 'symbol', type: 'string', indexed: false },
      { name: 'quote', type: 'address', indexed: true },
    ],
  },
  {
    type: 'event',
    name: 'Buy',
    inputs: [
      { name: 'token', type: 'address', indexed: true },
      { name: 'buyer', type: 'address', indexed: true },
      { name: 'quoteIn', type: 'uint256', indexed: false },
      { name: 'taxDividend', type: 'uint256', indexed: false },
      { name: 'taxPlatform', type: 'uint256', indexed: false },
      { name: 'tokensOut', type: 'uint256', indexed: false },
      { name: 'realQuote', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'Sell',
    inputs: [
      { name: 'token', type: 'address', indexed: true },
      { name: 'seller', type: 'address', indexed: true },
      { name: 'tokensIn', type: 'uint256', indexed: false },
      { name: 'taxDividend', type: 'uint256', indexed: false },
      { name: 'taxPlatform', type: 'uint256', indexed: false },
      { name: 'quoteOut', type: 'uint256', indexed: false },
      { name: 'realQuote', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'Graduated',
    inputs: [
      { name: 'token', type: 'address', indexed: true },
      { name: 'pair', type: 'address', indexed: true },
      { name: 'quote', type: 'address', indexed: false },
      { name: 'tokenAmount', type: 'uint256', indexed: false },
      { name: 'quoteAmount', type: 'uint256', indexed: false },
    ],
  },
]

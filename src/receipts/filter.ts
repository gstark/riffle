// Free first check before the model. Only messages that pass go to the model.
// Recall matters more than precision: the model rejects marketing email that passes.

const PURCHASE_WORD =
  /\b(?:order(?:s|ed)?|receipts?|invoices?|payments?|purchase[ds]?|subscriptions?|renewals?|renews|refund(?:s|ed)?|returns?|charged)\b/i;
/** A currency symbol or ISO code next to a number: "$12.99", "USD 12.99", "12,99 €". */
const CURRENCY_AMOUNT = /[$€£¥]\s?\d|\b(?:USD|EUR|GBP|CAD|AUD|JPY)\s?\d|\d\s?(?:€|(?:USD|EUR|GBP|CAD|AUD|JPY)\b)/i;
const SHIPPING_WORD = /\b(?:shipped|delivered|out for delivery|tracking)\b/i;
/** "order", an optional "no", "number", or "id", then an identifier of 6 or more characters with a digit. */
const ORDER_NUMBER = /\border\b\W{0,3}(?:(?:no|number|id)\b\W{0,3})?(?=[a-z0-9-]*\d)[a-z0-9][a-z0-9-]{5,}/i;

export function passesFilter(subject: string, text: string): boolean {
  const content = `${subject}\n${text}`;
  if (PURCHASE_WORD.test(content) && CURRENCY_AMOUNT.test(content)) return true;
  return SHIPPING_WORD.test(content) && ORDER_NUMBER.test(content);
}

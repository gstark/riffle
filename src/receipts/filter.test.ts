import { describe, expect, it } from "vitest";
import { passesFilter } from "./filter.ts";

describe("passesFilter", () => {
  it.each<[string, string, string]>([
    ["an order with a dollar amount", "Your Amazon.com order", "Order Total: $23.45"],
    ["a renewal with a currency code", "Your Netflix membership renews soon", "We will charge USD 15.49"],
    ["a euro amount after the number", "Receipt from Café Rouge", "Total 12,99 €"],
    ["a refund", "Your refund is on its way", "We refunded £8.00 to your card"],
    ["upper case", "ORDER CONFIRMATION", "TOTAL $5.00"],
    ["a shipping notice with an order number", "Shipped: your package", "Order #112-1234567-1234567 Track package"],
    ["an order number after 'No.'", "Delivered today", "Order No. 556677 was delivered"],
    ["a lower-case currency code", "Receipt", "usd 12.99"],
    ["an order number after 'ID:'", "Delivered", "Order ID: 112-1234567"],
    ["a plural purchase word", "Your payment receipts", "$5"],
    ["the word 'ordered'", "Ordered: USB cable", "$5"],
  ])("passes %s", (_name, subject, text) => {
    expect(passesFilter(subject, text)).toBe(true);
  });

  it.each<[string, string, string]>([
    ["a newsletter", "Weekly digest", "Read our latest articles"],
    ["an amount without a purchase word", "Lunch on Friday", "It was $12 each"],
    ["a delivery without an order number", "Your package was delivered", "Look at your front door"],
    ["a word that only looks like an order number", "Tracking your order confirmation", "Thanks for shopping"],
  ])("rejects %s", (_name, subject, text) => {
    expect(passesFilter(subject, text)).toBe(false);
  });
});

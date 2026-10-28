// The candidate receipt models on Bedrock. try-models.ts compares them on real mail.
// Each model calls one forced tool whose input schema is ExtractionSchema. Claude structured output cannot take this
// schema: it allows at most 16 nullable fields.

import { BedrockRuntimeClient, ConverseCommand, type ToolInputSchema } from "@aws-sdk/client-bedrock-runtime";
import { z } from "zod";
import { ExtractionSchema, parseExtraction, SYSTEM_PROMPT, type ReceiptModel } from "./extract-receipt.ts";

/** The US inference profile. This account can call Haiku 5.5 only from us-east-1. */
export const HAIKU_5_5_MODEL = "us.anthropic.claude-haiku-5-5";
const HAIKU_5_5_REGION = "us-east-1";
/** The baseline for try-models.ts. */
export const HAIKU_4_5_MODEL = "us.anthropic.claude-haiku-4-5-20251001-v1:0";

const MAX_TOKENS = 4_000;
const TOOL_NAME = "record_receipts";
const TOOL_DESCRIPTION = "Records the purchases in the email.";

function inputSchema(): ToolInputSchema {
  const json = z.toJSONSchema(ExtractionSchema);
  delete json.$schema;
  return { json: json as unknown as ToolInputSchema.JsonMember["json"] };
}

/** Haiku 5.5 rejects a temperature other than the default, so only Haiku 4.5 sets one. */
function createConverseModel(id: string, client: BedrockRuntimeClient, temperature?: number): ReceiptModel {
  const schema = inputSchema();
  return {
    id,
    async extract(input) {
      const response = await client.send(
        new ConverseCommand({
          modelId: id,
          system: [{ text: SYSTEM_PROMPT }],
          messages: [{ role: "user", content: [{ text: input }] }],
          toolConfig: {
            tools: [{ toolSpec: { name: TOOL_NAME, description: TOOL_DESCRIPTION, inputSchema: schema } }],
            toolChoice: { tool: { name: TOOL_NAME } },
          },
          inferenceConfig: { maxTokens: MAX_TOKENS, temperature },
        }),
      );
      const toolUse = response.output?.message?.content?.find((block) => block.toolUse)?.toolUse;
      if (!toolUse) throw new Error(`${id} gave no output (stop reason ${response.stopReason})`);
      return parseExtraction(toolUse.input);
    },
  };
}

export const createHaiku55Model = (client = new BedrockRuntimeClient({ region: HAIKU_5_5_REGION })) =>
  createConverseModel(HAIKU_5_5_MODEL, client);
export const createHaiku45Model = (client = new BedrockRuntimeClient()) =>
  createConverseModel(HAIKU_4_5_MODEL, client, 0);

/** The model that the receipts Lambda uses. Selected with try-models.ts on 2026-10-28. */
export const createReceiptModel = createHaiku55Model;

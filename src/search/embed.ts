// Titan Text Embeddings v2 on Bedrock. The vectors are normalized, so cosine distance works.

import { BedrockRuntimeClient, InvokeModelCommand, ValidationException } from "@aws-sdk/client-bedrock-runtime";
import { z } from "zod";
import { DIMENSIONS } from "./schema.ts";

export type Embed = (text: string) => Promise<number[]>;

const MODEL_ID = "amazon.titan-embed-text-v2:0";

const TitanResponseSchema = z.object({ embedding: z.array(z.number()).length(DIMENSIONS) });

export function createTitanEmbed(client = new BedrockRuntimeClient()): Embed {
  const embed = async (text: string, attempt = 0): Promise<number[]> => {
    try {
      const response = await client.send(
        new InvokeModelCommand({
          modelId: MODEL_ID,
          contentType: "application/json",
          accept: "application/json",
          body: JSON.stringify({ inputText: text, dimensions: DIMENSIONS, normalize: true }),
        }),
      );
      return TitanResponseSchema.parse(JSON.parse(new TextDecoder().decode(response.body))).embedding;
    } catch (error) {
      // Text with many tokens per character (URLs, non-Latin scripts) can pass the 8,192-token limit.
      // Titan rejects it with a ValidationException. Try again with half the text.
      if (error instanceof ValidationException && attempt < 3 && text.length > 100) {
        return embed(text.slice(0, Math.floor(text.length / 2)), attempt + 1);
      }
      throw error;
    }
  };
  return (text) => embed(text);
}

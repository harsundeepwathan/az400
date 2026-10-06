import { test } from "node:test";
import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import { createMealScanServer } from "../src/server.js";
import { detectMediaType, type MessagesClient } from "../src/analyze.js";

const JPEG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(32)]);

function fakeClient(reply: object, capture: { request?: any } = {}): MessagesClient {
  return {
    beta: {
      messages: {
        create: (async (request: any) => {
          capture.request = request;
          return reply;
        }) as any,
      },
    },
  };
}

function textReply(payload: object) {
  return { stop_reason: "end_turn", content: [{ type: "text", text: JSON.stringify(payload) }] };
}

async function post(client: MessagesClient, body: unknown, key = "secret") {
  const server = createMealScanServer({ client, appKey: "secret" }).listen(0);
  const { port } = server.address() as AddressInfo;
  try {
    const res = await fetch(`http://127.0.0.1:${port}/v1/meal-scan`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Vector-Key": key },
      body: JSON.stringify(body),
    });
    return { status: res.status, json: (await res.json()) as any };
  } finally {
    server.close();
  }
}

const plate = {
  no_food_detected: false,
  items: [
    { name: "Chicken breast, grilled", grams: 180, calories: 297, protein: 55.8, carbs: 0, fat: 6.5, confidence: 0.9,
      alternatives: ["Chicken thigh", "Turkey breast", "Tofu", "Pork loin"] },
    { name: "White rice", grams: 200, calories: 260, protein: 5.4, carbs: 56.4, fat: 0.6, confidence: 0.85, alternatives: [] },
  ],
};

test("returns items in the app's contract and sends a well-formed request", async () => {
  const capture: { request?: any } = {};
  const { status, json } = await post(fakeClient(textReply(plate), capture), { image: JPEG.toString("base64") });
  assert.equal(status, 200);
  assert.equal(json.items.length, 2);
  assert.equal(json.items[0].alternatives.length, 3, "alternatives are capped at 3");
  assert.equal(capture.request.model, "claude-opus-5-5");
  assert.equal(capture.request.fallbacks, "default");
  assert.deepEqual(capture.request.betas, ["server-side-fallback-2026-07-01"]);
  assert.equal(capture.request.output_config.format.type, "json_schema");
  assert.equal(capture.request.messages[0].content[0].source.media_type, "image/jpeg");
});

test("no food and refusals become an empty list", async () => {
  const none = await post(fakeClient(textReply({ no_food_detected: true, items: [] })), { image: JPEG.toString("base64") });
  assert.deepEqual(none.json, { items: [] });
  const refused = await post(fakeClient({ stop_reason: "refusal", stop_details: { explanation: "x" }, content: [] }),
    { image: JPEG.toString("base64") });
  assert.deepEqual(refused.json, { items: [] });
});

test("rejects bad keys, bad bodies and non-images", async () => {
  const client = fakeClient(textReply(plate));
  assert.equal((await post(client, { image: JPEG.toString("base64") }, "wrong")).status, 401);
  assert.equal((await post(client, { nope: 1 })).status, 400);
  assert.equal((await post(client, { image: Buffer.from("hello world, not an image").toString("base64") })).status, 400);
});

test("malformed model output is a 502, not a crash", async () => {
  const res = await post(fakeClient({ stop_reason: "end_turn", content: [{ type: "text", text: "{\"items\": [{\"name\": 1}]}" }] }),
    { image: JPEG.toString("base64") });
  assert.equal(res.status, 502);
});

test("detects image types from magic bytes", () => {
  assert.equal(detectMediaType(JPEG), "image/jpeg");
  assert.equal(detectMediaType(Buffer.from("not an image at all")), null);
});

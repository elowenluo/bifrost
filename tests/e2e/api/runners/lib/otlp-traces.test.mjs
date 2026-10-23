import assert from 'node:assert/strict';
import test from 'node:test';
import { decodeOtlpSpans } from './otlp-traces.mjs';

// Hand-encoded protobuf, so the decoder is checked against the wire format itself.
const varint = (n) => { const out = []; let v = BigInt(n); do { let b = Number(v & 0x7fn); v >>= 7n; if (v) b |= 0x80; out.push(b); } while (v); return out; };
const len = (field, bytes) => [...varint((field << 3) | 2), ...varint(bytes.length), ...bytes];
const str = (field, s) => len(field, [...Buffer.from(s, 'utf8')]);
const kv = (key, anyValue) => len(9, [...str(1, key), ...len(2, anyValue)]);
const span = (traceId, name, attrs) => len(2, [...len(1, [...Buffer.from(traceId, 'hex')]), ...str(5, name), ...attrs.flat()]);
const request = (...spans) => Buffer.from(len(1, len(2, spans.flat())));

test('decodeOtlpSpans reads trace ids, names and string, array and int attributes', () => {
  const body = request(
    span('0102030405060708090a0b0c0d0e0f10', 'bifrost.request', [kv('bifrost.request.id', str(1, 'req-1'))]),
    span('0102030405060708090a0b0c0d0e0f10', 'llm.call', [
      kv('gen_ai.response.finish_reason', str(1, 'refusal')),
      kv('gen_ai.response.finish_reasons', len(5, len(1, str(1, 'refusal')))),
      kv('http.response.status_code', [...varint((3 << 3) | 0), ...varint(200)]),
    ]),
  );
  const spans = decodeOtlpSpans(body);
  assert.equal(spans.length, 2);
  assert.equal(spans[0].traceId, '0102030405060708090a0b0c0d0e0f10');
  assert.equal(spans[0].attributes['bifrost.request.id'], 'req-1');
  assert.equal(spans[1].name, 'llm.call');
  assert.equal(spans[1].attributes['gen_ai.response.finish_reason'], 'refusal');
  assert.deepEqual(spans[1].attributes['gen_ai.response.finish_reasons'], ['refusal']);
  assert.equal(spans[1].attributes['http.response.status_code'], 200);
});

test('decodeOtlpSpans refuses a truncated body instead of returning partial spans', () => {
  const body = request(span('0102030405060708090a0b0c0d0e0f10', 'x', [kv('k', str(1, 'v'))]));
  assert.throws(() => decodeOtlpSpans(body.subarray(0, body.length - 3)));
});

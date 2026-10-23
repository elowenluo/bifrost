// Minimal decoder for OTLP/HTTP protobuf trace exports (ExportTraceServiceRequest),
// enough to read spans and their attributes in local runners without a protobuf
// dependency. Field numbers follow opentelemetry/proto/trace/v1 and common/v1.

const readVarint = (buf, pos) => {
  let result = 0n;
  let shift = 0n;
  for (;;) {
    if (pos >= buf.length) throw new Error("truncated varint");
    const byte = buf[pos++];
    result |= BigInt(byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return [result, pos];
    shift += 7n;
  }
};

// fields yields [fieldNumber, wireType, value] for one message; length-delimited
// values are subarrays, varints are BigInts, fixed values are subarrays.
function* fields(buf) {
  let pos = 0;
  while (pos < buf.length) {
    let tag;
    [tag, pos] = readVarint(buf, pos);
    const field = Number(tag >> 3n);
    const wire = Number(tag & 7n);
    if (wire === 0) {
      let value;
      [value, pos] = readVarint(buf, pos);
      yield [field, wire, value];
    } else if (wire === 2) {
      let length;
      [length, pos] = readVarint(buf, pos);
      const end = pos + Number(length);
      if (end > buf.length) throw new Error("truncated length-delimited field");
      yield [field, wire, buf.subarray(pos, end)];
      pos = end;
    } else if (wire === 1 || wire === 5) {
      const size = wire === 1 ? 8 : 4;
      yield [field, wire, buf.subarray(pos, pos + size)];
      pos += size;
    } else {
      throw new Error(`unsupported wire type ${wire}`);
    }
  }
}

const decodeAnyValue = (buf) => {
  for (const [field, , value] of fields(buf)) {
    switch (field) {
      case 1: return Buffer.from(value).toString("utf8");
      case 2: return value !== 0n;
      case 3: return Number(BigInt.asIntN(64, value));
      case 4: return Buffer.from(value).readDoubleLE(0);
      case 5: {
        const values = [];
        for (const [f, , item] of fields(value)) if (f === 1) values.push(decodeAnyValue(item));
        return values;
      }
      default: break;
    }
  }
  return null;
};

const decodeSpan = (buf) => {
  const span = { traceId: "", name: "", attributes: {} };
  for (const [field, , value] of fields(buf)) {
    if (field === 1) span.traceId = Buffer.from(value).toString("hex");
    else if (field === 5) span.name = Buffer.from(value).toString("utf8");
    else if (field === 9) {
      let key = "";
      let attr = null;
      for (const [f, , v] of fields(value)) {
        if (f === 1) key = Buffer.from(v).toString("utf8");
        else if (f === 2) attr = decodeAnyValue(v);
      }
      span.attributes[key] = attr;
    }
  }
  return span;
};

// decodeOtlpSpans returns every span in an ExportTraceServiceRequest body as
// { traceId (hex), name, attributes: { key: string | boolean | number | array } }.
export const decodeOtlpSpans = (body) => {
  const spans = [];
  for (const [rsField, , resourceSpans] of fields(body)) {
    if (rsField !== 1) continue;
    for (const [ssField, , scopeSpans] of fields(resourceSpans)) {
      if (ssField !== 2) continue;
      for (const [spanField, , span] of fields(scopeSpans)) {
        if (spanField === 2) spans.push(decodeSpan(span));
      }
    }
  }
  return spans;
};

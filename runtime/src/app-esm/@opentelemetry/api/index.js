// Minimal OpenTelemetry API surface used by the embedded DSH SDK graph.
const VERSION = '1.9.0';
const SPAN_KEY = Symbol.for('opentelemetry.context.span');
const BAGGAGE_KEY = Symbol.for('opentelemetry.context.baggage');
const ROOT_CONTEXT = new (class Context {
    constructor(parent, values) { this.parent = parent || null; this.values = values || new Map(); }
    getValue(key) { return this.values.has(key) ? this.values.get(key) : (this.parent ? this.parent.getValue(key) : undefined); }
    setValue(key, value) { const next = new Map(this.values); next.set(key, value); return new Context(this, next); }
    deleteValue(key) { const next = new Map(this.values); next.delete(key); return new Context(this, next); }
})();
let activeContext = ROOT_CONTEXT;
const context = {
    active() { return activeContext; },
    with(ctx, fn, thisArg) { const previous = activeContext; activeContext = ctx || ROOT_CONTEXT; try { return fn.apply(thisArg, Array.prototype.slice.call(arguments, 3)); } finally { activeContext = previous; } },
    bind(ctx, target) { if (typeof target !== 'function') return target; const bound = ctx || ROOT_CONTEXT; return function () { return context.with.apply(context, [bound, target, this].concat(Array.prototype.slice.call(arguments))); }; },
    enable() {}, disable() {}
};
function createContextKey(description) { return Symbol.for('opentelemetry.context.' + String(description)); }
const INVALID_TRACEID = '00000000000000000000000000000000';
const INVALID_SPANID = '0000000000000000';
const INVALID_SPAN_CONTEXT = { traceId: INVALID_TRACEID, spanId: INVALID_SPANID, traceFlags: 0 };
function validHex(value, length) { return typeof value === 'string' && value.length === length && /^[0-9a-f]+$/i.test(value); }
function isSpanContextValid(value) { return !!value && validHex(value.traceId, 32) && value.traceId !== INVALID_TRACEID && validHex(value.spanId, 16) && value.spanId !== INVALID_SPANID; }
function isValidTraceId(value) { return validHex(value, 32) && value !== INVALID_TRACEID; }
function isValidSpanId(value) { return validHex(value, 16) && value !== INVALID_SPANID; }
class NoopSpan { constructor(sc) { this.sc = sc || INVALID_SPAN_CONTEXT; } spanContext() { return this.sc; } isRecording() { return false; } setAttribute() { return this; } setAttributes() { return this; } addEvent() { return this; } addLink() { return this; } addLinks() { return this; } setStatus() { return this; } updateName() { return this; } recordException() {} end() {} }
const INVALID_SPAN = new NoopSpan();
const NOOP_TRACER = { startSpan() { return new NoopSpan(); }, startActiveSpan(name, options, ctx, fn) { const callback = typeof options === 'function' ? options : (typeof ctx === 'function' ? ctx : fn); return typeof callback === 'function' ? callback(new NoopSpan()) : new NoopSpan(); } };
let tracerProvider = { getTracer() { return NOOP_TRACER; } };
const trace = {
    getSpan(ctx) { return (ctx || context.active()).getValue(SPAN_KEY) || INVALID_SPAN; },
    getSpanContext(ctx) { const span = this.getSpan(ctx); return span.spanContext ? span.spanContext() : undefined; },
    setSpan(ctx, span) { return (ctx || context.active()).setValue(SPAN_KEY, span); }, deleteSpan(ctx) { return (ctx || context.active()).deleteValue(SPAN_KEY); },
    setSpanContext(ctx, sc) { return (ctx || context.active()).setValue(SPAN_KEY, new NoopSpan(sc)); }, getActiveSpan() { return this.getSpan(context.active()); },
    getTracerProvider() { return tracerProvider; }, getTracer() { return tracerProvider.getTracer.apply(tracerProvider, arguments); },
    setGlobalTracerProvider(provider) { tracerProvider = provider || tracerProvider; return true; }, disable() {}, wrapSpanContext(sc) { return new NoopSpan(sc); }
};
function createNoopMeter() { const instrument = { add() {}, record() {}, observe() {}, enable() {}, disable() {} }; return { createCounter() { return instrument; }, createUpDownCounter() { return instrument; }, createHistogram() { return instrument; }, createGauge() { return instrument; }, createObservableGauge() { return instrument; }, createObservableCounter() { return instrument; }, createObservableUpDownCounter() { return instrument; }, addBatchObservableCallback() {}, removeBatchObservableCallback() {} }; }
let meterProvider = { getMeter() { return createNoopMeter(); } };
const metrics = { getMeterProvider() { return meterProvider; }, getMeter() { return meterProvider.getMeter.apply(meterProvider, arguments); }, setGlobalMeterProvider(provider) { meterProvider = provider || meterProvider; return true; }, disable() {} };
const noop = function () {};
const diag = { error: noop, warn: noop, info: noop, debug: noop, verbose: noop, setLogger() { return true; }, setLogLevel() {}, getLogger() { return this; }, createComponentLogger() { return this; }, disable() {} };
const propagation = { inject() {}, extract(ctx) { return ctx || context.active(); }, fields() { return []; }, setGlobalPropagator() { return true; }, disable() {} };
class Baggage { constructor(entries) { this.entries = Object.assign({}, entries || {}); } getEntry(k) { return this.entries[k]; } getAllEntries() { return Object.keys(this.entries).map((k) => [k, this.entries[k]]); } setEntry(k, v) { const next = Object.assign({}, this.entries); next[k] = v; return new Baggage(next); } removeEntry(k) { const next = Object.assign({}, this.entries); delete next[k]; return new Baggage(next); } }
function createBaggage(entries) { return new Baggage(entries); }
const baggage = { createBaggage, getBaggage(ctx) { return (ctx || context.active()).getValue(BAGGAGE_KEY); }, setBaggage(ctx, value) { return (ctx || context.active()).setValue(BAGGAGE_KEY, value); }, deleteBaggage(ctx) { return (ctx || context.active()).deleteValue(BAGGAGE_KEY); } };
const baggageEntryMetadataFromString = (value) => typeof value === 'string' ? { toString() { return value; } } : undefined;
const TraceFlags = { NONE: 0, SAMPLED: 1 };
const ValueType = { INT: 0, DOUBLE: 1 };
const DiagLogLevel = { NONE: 0, ERROR: 30, WARN: 50, INFO: 60, DEBUG: 70, VERBOSE: 80, ALL: 9999 };
const DiagConsoleLogger = class { error() {} warn() {} info() {} debug() {} verbose() {} };
const SpanKind = { INTERNAL: 0, SERVER: 1, CLIENT: 2, PRODUCER: 3, CONSUMER: 4 };
const SpanStatusCode = { UNSET: 0, OK: 1, ERROR: 2 };
const SamplingDecision = { NOT_RECORD: 0, RECORD: 1, RECORD_AND_SAMPLED: 2 };
const ProxyTracer = class { startSpan() { return new NoopSpan(); } };
const ProxyTracerProvider = class { getTracer() { return NOOP_TRACER; } };
export { VERSION, ROOT_CONTEXT, context, createContextKey, trace, metrics, propagation, baggage, diag, createBaggage, baggageEntryMetadataFromString, createNoopMeter, isSpanContextValid, isValidTraceId, isValidSpanId, INVALID_TRACEID, INVALID_SPANID, INVALID_SPAN_CONTEXT, TraceFlags, ValueType, DiagLogLevel, DiagConsoleLogger, SpanKind, SpanStatusCode, SamplingDecision, ProxyTracer, ProxyTracerProvider };
export default { context, trace, metrics, propagation, baggage, diag };

// typebox stub（pi-ai 的 schema 面（Type.String/Object 等——链式构造+静态面简配）
const wrap = (def) => {
  const s = (props = {}) => ({ ...def, ...props })
  const chained = Object.assign(s, {
    String: () => wrap({ kind: 'string' }),
    Number: () => wrap({ kind: 'number' }),
    Boolean: () => wrap({ kind: 'boolean' }),
    Array: (t) => wrap({ kind: 'array', items: t }),
    Object: (props) => wrap({ kind: 'object', properties: props }),
    Union: (...ts) => wrap({ kind: 'union', items: ts }),
    Union: Object.assign(s.Union || ((...ts) => wrap({ kind: 'union', items: ts })), {}),
    Literal: (v) => wrap({ kind: 'literal', value: v }),
    Integer: () => wrap({ kind: 'integer' }),
    Null: () => wrap({ kind: 'null' }),
    Tuple: (...ts) => wrap({ kind: 'tuple', items: ts }),
    Optional: (t) => wrap({ ...(t?.[0] || {}), optional: true }),
    Nullable: (t) => wrap({ ...(t?.[0] || {}), nullable: true }),
    Ref: (r) => wrap({ kind: 'ref', ref: r }),
    Record: (k, v) => wrap({ kind: 'record', key: k, value: v }),
    Intersect: (...ts) => wrap({ kind: 'intersect', items: ts }),
    Any: () => wrap({ kind: 'any' }),
    Unknown: () => wrap({ kind: 'unknown' }),
    Never: () => wrap({ kind: 'never' }),
    Promise: (t) => wrap({ kind: 'promise', value: t }),
    Function: (a, r) => wrap({ kind: 'function', args: a, returns: r }),
    Symbol: () => wrap({ kind: 'symbol' }),
    Undefined: () => wrap({ kind: 'undefined' }),
    Date: () => wrap({ kind: 'date' }),
    Uint8Array: () => wrap({ kind: 'uint8array' }),
    ArrayBuffer: () => wrap({ kind: 'arraybuffer' }),
    Not: (t) => wrap({ kind: 'not', value: t }),
  })
  return chained
}
export const Type = wrap({ kind: 'static' })
export const Kind = Symbol.for('TypeBox.Kind')
export const CreateType = (s) => wrap(s)
export const TypeRegistry = { Set() {}, Get() { return undefined }, Has() { return false }, Clear() {} }
export const FormatRegistry = { Set() {}, Get() { return undefined }, Has() { return false }, Clear() {} }
export const Value = { Check: () => true, Create: (s) => s, Clone: (v) => JSON.parse(JSON.stringify(v)), Equal: (a, b) => JSON.stringify(a) === JSON.stringify(b), Diff: () => [], Patch: (v) => v, Delete: () => {}, Errors: () => [], Hash: () => '' }
export const Static = undefined
export default { Type, Kind, Value }

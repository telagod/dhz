// typebox/$sub stub（pi-ai 子路径面——真实现留档）
export const Value = { Check: () => true, Create: (s) => s, Clone: (v) => JSON.parse(JSON.stringify(v)), Equal: (a, b) => JSON.stringify(a) === JSON.stringify(b), Diff: () => [], Patch: (v) => v, Delete: () => {}, Errors: () => [], Hash: () => '', Merge: (a, b) => ({ ...a, ...b }) }
export const Type = { String: () => ({}), Number: () => ({}), Boolean: () => ({}), Array: (t) => ({ items: t }), Object: (p) => ({ properties: p }), Union: (...ts) => ({ items: ts }), Literal: (v) => ({ value: v }) }
export const Kind = Symbol.for('TypeBox.Kind')
export default { Value, Type }

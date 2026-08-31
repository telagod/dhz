// typebox/compile stub（TypeCompiler——pi-ai schema 编译面——真编译留档）
export class TypeCompiler {
  static Compile(schema, options) {
    const fn = (v) => v
    return { schema, Encode: fn, Decode: fn, Check: (v) => { try { fn(v); return true } catch (e) { return false } }, Errors: () => [], Code: () => 'return true' }
  }
}
export const Compile = (schema, options) => TypeCompiler.Compile(schema, options)
export default { TypeCompiler, Compile }

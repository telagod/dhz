// picomatch stub（glob→regex——简化面；完整 glob 面留档）
function picomatch(pattern, opts) {
  const src = String(pattern || '')
  const re = new RegExp('^' + src.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*/g, '\u0000').replace(/\*/g, '[^/]*').replace(/\u0000/g, '.*').replace(/\?/g, '.') + '$')
  const m = (s) => re.test(String(s || ''))
  m.pattern = src
  m.regexp = re
  return m
}
picomatch.scan = () => ({})
export { picomatch }
export default picomatch

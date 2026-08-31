// @babel/code-frame stub（SyntaxError 帧渲染——简化面；完整高亮留档）
export function codeFrameColumns(rawLines, loc, opts) {
  const lines = String(rawLines || '').split('\n')
  const start = loc && loc.start && loc.start.line ? loc.start.line : 1
  const line = lines[start - 1] || ''
  const col = loc && loc.start && loc.start.column ? loc.start.column + 1 : 1
  return '> ' + start + ' | ' + line + '\n' + ' '.repeat(3 + col) + '^'
}
export default { codeFrameColumns }

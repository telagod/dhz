// CJS 样本（module.exports 形——default-only 起步面）
const dep = require('./cjs-dep')
const base = dep.base
module.exports = { answer: base + 2, doubled: (base + 2) * 2, cycleOk: dep.cycleOk }

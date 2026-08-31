import { tag } from 'node:fs'
import { n } from './dep.mjs'

globalThis.__result = tag + ':' + n

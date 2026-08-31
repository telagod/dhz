// detect-libc stub（glibc 面——跨平台探测留档）
export function detectLibcSync() { return 'glibc' }
export function detectLibc() { return Promise.resolve('glibc') }
export function familySync() { return 'glibc' }
export function family() { return Promise.resolve('glibc') }
export const GLIBC = 'glibc'
export const MUSL = 'musl'
export function versionSync() { return '2.36' }
export function version() { return Promise.resolve('2.36') }
export function isNonGlibcLinuxSync() { return false }
export default { detectLibcSync, detectLibc, familySync, family, GLIBC, MUSL, versionSync, version, isNonGlibcLinuxSync }

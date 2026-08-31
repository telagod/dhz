// Embedded OTLP/HTTP exporter: keep the SDK exporter contract without Node socket transport.
const SUCCESS = 0;
const FAILED = 1;
function toJsonRecord(record) {
    return {
        timeUnixNano: record && (record.timestamp ?? record.observedTimestamp),
        severityNumber: record && record.severityNumber,
        severityText: record && record.severityText,
        body: record && record.body,
        attributes: record && record.attributes,
        droppedAttributesCount: record && record.droppedAttributesCount,
    };
}
export class OTLPLogExporter {
    constructor(config = {}) { this.url = config.url; this.headers = config.headers || {}; this._shutdown = false; }
    export(records, callback) {
        if (this._shutdown) { callback({ code: FAILED, error: new Error('OTLPLogExporter is shut down') }); return; }
        const payload = { resourceLogs: [{ resource: {}, scopeLogs: [{ scope: {}, logRecords: (records || []).map(toJsonRecord) }] }] };
        if (!this.url || typeof globalThis.fetch !== 'function') { callback({ code: FAILED, error: new Error('OTLPLogExporter: fetch or url unavailable') }); return; }
        Promise.resolve(globalThis.fetch(this.url, { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, this.headers), body: JSON.stringify(payload) }))
            .then((response) => { if (!response || response.ok === false) throw new Error('OTLPLogExporter: HTTP export failed'); callback({ code: SUCCESS }); })
            .catch((error) => callback({ code: FAILED, error }));
    }
    forceFlush() { return Promise.resolve(); }
    shutdown() { this._shutdown = true; return Promise.resolve(); }
}
export default OTLPLogExporter;
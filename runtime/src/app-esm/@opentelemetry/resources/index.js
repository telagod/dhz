// Minimal resource API for the embedded telemetry provider.
class Resource {
    constructor(attributes = {}, schemaUrl) { this.attributes = attributes; this.schemaUrl = schemaUrl; this.asyncAttributesPending = false; }
    getRawAttributes() { return Object.entries(this.attributes); }
    waitForAsyncAttributes() { return Promise.resolve(); }
    merge(other) { return new Resource(Object.assign({}, this.attributes, other ? other.attributes : {}), other && other.schemaUrl || this.schemaUrl); }
}
export function resourceFromAttributes(attributes, options) { return new Resource(attributes, options && options.schemaUrl); }
export function resourceFromDetectedResource(resource, options) { return new Resource(resource && resource.attributes || {}, options && options.schemaUrl); }
export function emptyResource() { return new Resource(); }
export function defaultResource() { return new Resource(); }
export function detectResources() { return Promise.resolve(emptyResource()); }
export { Resource };
export default Resource;

// Imports must resolve UPWARD to the image's shared @clusterio copies. A local
// duplicate that drags its own @clusterio/lib along is rejected fatally by
// Clusterio's singleton check; one that does not is caught by the resolve
// check below. Either way this log line never appears.
import { BaseControllerPlugin } from "@clusterio/controller";

export default async function(context) {
	const resolved = import.meta.resolve("@clusterio/controller");
	if (resolved.includes("/ci_fixture/node_modules/")) {
		throw new Error("@clusterio/controller resolved to a local duplicate: " + resolved);
	}
	if (typeof BaseControllerPlugin !== "function") {
		throw new Error("@clusterio/controller did not export BaseControllerPlugin");
	}
	context.logger.info("ci_fixture controller plugin loaded");
}

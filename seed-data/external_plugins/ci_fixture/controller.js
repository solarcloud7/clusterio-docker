// Imports must resolve UPWARD to the image's shared @clusterio copies —
// if a local duplicate survived in this plugin's node_modules, Clusterio
// fatally rejects the second @clusterio/lib and this log line never appears.
import { BaseControllerPlugin } from "@clusterio/controller";

export default async function(context) {
	// The import is what the dedup check proves; keep it referenced.
	if (typeof BaseControllerPlugin !== "function") {
		throw new Error("@clusterio/controller did not resolve to the shared copy");
	}
	context.logger.info("ci_fixture controller plugin loaded");
}

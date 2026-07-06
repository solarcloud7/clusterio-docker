// Requires must resolve UPWARD to the image's shared @clusterio copies —
// if a local duplicate survived in this plugin's node_modules, Clusterio
// fatally rejects the second @clusterio/lib and this log line never appears.
"use strict";
const { BaseControllerPlugin } = require("@clusterio/controller");

class ControllerPlugin extends BaseControllerPlugin {
	async init() {
		this.logger.info("ci_fixture controller plugin loaded");
	}
}

module.exports = { ControllerPlugin };

// CI fixture plugin — the smallest external plugin that exercises the full
// lifecycle: npm install (peer deps planted), the entrypoint's @clusterio
// dedup strip, keyword-gated auto-discovery, and controller load.
// The "clusterio-plugin" keyword in package.json is LOAD-BEARING: without it
// Clusterio's loadPluginList never registers the plugin and it silently no-ops.
"use strict";

module.exports = {
	plugin: {
		name: "ci_fixture",
		title: "CI Fixture",
		description: "Proves external plugin install + discovery + load in CI.",
		controllerEntrypoint: "controller",
	},
};

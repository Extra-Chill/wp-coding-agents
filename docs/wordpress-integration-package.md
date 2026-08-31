# WordPress integration package

`wp-coding-agents-integration` is the canonical regular WordPress plugin for retained in-process contracts owned by wp-coding-agents. It is selected through the normalized installation profile's explicit carried-plugin intent and receives normal activation and fatal-error recovery semantics.

Generated MU-plugins remain limited to installation governance that must always load, such as runtime registration, channel transport, inbound events, and source reconciliation. Host installation, repository policy, and Homeboy lifecycle stay outside the WordPress package.

The initial package keeps `WpCodingAgents\Integration\HostCapabilities` private to the provider package and adapts its probes onto Intelligence-owned `intelligence_host_has_shell` and `intelligence_host_has_writable_content_directory` filters. Intelligence and Data Machine do not reference this package or namespace. No DMC workspace, GitHub, ability, flow, task, or lifecycle implementation is included.

# WordPress integration package

`wp-coding-agents-integration` is the canonical regular WordPress plugin for retained in-process contracts owned by wp-coding-agents. It is selected through the normalized installation profile's explicit carried-plugin intent and receives normal activation and fatal-error recovery semantics.

Generated MU-plugins remain limited to installation governance that must always load, such as runtime registration, channel transport, inbound events, and source reconciliation. Host installation, repository policy, and Homeboy lifecycle stay outside the WordPress package.

The package owns two generic, fail-closed host-execution contracts: `wp_coding_agents_host_can_execute_processes` and `wp_coding_agents_host_has_writable_process_workspace`. Each filter receives `false`; the installed integration declares process support only after its shell probe and the CLI transport's `proc_open`, POSIX cleanup, and session-launcher requirements succeed. Consumers inspect these filters directly and do not depend on this package's PHP namespace. The package's Intelligence adapters consume the same declarations, including the writable-workspace declaration. No product, Studio, or host-profile logic belongs in the contract.

`WpCodingAgents\Integration\HostCapabilities` remains private to the provider package and adapts its probes onto Intelligence-owned `intelligence_host_has_shell` and `intelligence_host_has_writable_content_directory` filters. Intelligence and Data Machine do not reference this package or namespace. No DMC workspace, GitHub, ability, flow, task, or lifecycle implementation is included.

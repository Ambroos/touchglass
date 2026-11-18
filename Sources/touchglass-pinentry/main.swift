// touchglass-pinentry: the pinentry-program for gpg-agent. See PinentryServer.
PinentryServer(config: Config.load(), arguments: Array(CommandLine.arguments.dropFirst())).run()

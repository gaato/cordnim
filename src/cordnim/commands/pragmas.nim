## Declarative pragmas consumed by the command compiler.

import ./spec
import cordnim/core/permissions

template discordCommand*(
    name: static[string];
    description: static[string];
    installs: static[set[CommandInstallContext]] = {guildInstall};
    contexts: static[set[CommandInteractionContext]] = {guildChannel};
    kind: static[CommandKind] = ckChatInput;
    ack: static[CommandAckKind] = ackManual;
    autoDeferAfterMs: static[int] = 2_000;
    ephemeral: static[bool] = true;
    requiredBotPermissions: static[set[Permission]] = {}
  ) {.pragma.} ## Marks a typed procedure as an application command declaration.

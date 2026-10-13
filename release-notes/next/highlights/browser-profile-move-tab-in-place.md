title: Move a tab to another browser profile without losing its place
category: new
action: browserProfile.moveTab | Try it

Move Tab to Browser Profile now keeps the tab: same place, same tab, and the page reloads at the same address in the new profile, with that profile's cookies, site data and permissions. Back and forward history starts over in the new profile. Agents can create browser profiles, open a tab in one and move a tab to another from the command line or over MCP: `cmux browser profile create --name Work`, `cmux browser tab open --url <url> --profile Work` and `cmux browser tab <tab> set-profile --profile Work`. Agents cannot delete a profile.

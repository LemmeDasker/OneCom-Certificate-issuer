# Certificate scripts

This folder contains the one.com / Posh-ACME scripts for managing the Let's Encrypt certificate for your domain (DNS-01 via the **OneCom** plugin).

## Automated installation (recommended)

The `Setup` folder is a self-contained installation package that is not tied to a specific domain. Copy the `Setup` folder to the PC (any location except `C:\Certificate`) and double-click `Install.cmd`. It asks for administrator rights (UAC) and then:

1. Creates `C:\Certificate` with `Certificates`, `Hooks`, `Logs` and `Scripts`, restricted to SYSTEM, Administrators and the installing user.
2. Asks for the domain(s), contact e-mail and one.com domain and saves them in `config.json`.
3. Installs Posh-ACME (only if it is missing) and copies the OneCom plugin into every installed version.
4. Saves the one.com login with DPAPI after testing it against one.com.
5. Requests a Let's Encrypt **staging** certificate. Only if that succeeds does it ask you to type `PROD` and request the production certificate.
6. Copies the certificate to `C:\Certificate\Certificates\<domain>\` (`fullchain.cer`, `cert.key`, `cert.cer`, `chain.cer`, `cert.pfx`, `fullchain.pfx`).
7. Creates the scheduled tasks `\Certificate\Fornyelse (produktion)` (daily) and `\Certificate\Test (staging)` (weekly).

You can run it again at any time, for example to change domains or update the one.com password. Steps that are already done are reused.

### Domains and the one.com domain

The installer asks for two different things that are easy to mix up:

- **Domain(s)**: the hostnames the certificate must cover, for example `www.mydomain.com`. The first one is the *main domain*. It decides the certificate's folder name under `C:\Certificate\Certificates\`.
- **one.com domain**: the domain registered at one.com where the DNS zone is hosted, for example `mydomain.com`. The script uses it to create and remove the `_acme-challenge` TXT record that Let's Encrypt needs to validate the certificate. Every domain in the list must belong to this zone. It is not a password: the one.com login is asked for separately and saved encrypted with DPAPI (not in `config.json`).

#### Running the installer again with other domains

`config.json` describes exactly **one** certificate. Running the installer again does not add a second certificate. It replaces the previous domain list:

- If you first enter `www.mydomain.com` and later run it again with only `blog.mydomain.com`, the main domain changes and a **new** certificate is ordered for `blog.mydomain.com`, saved in `C:\Certificate\Certificates\blog.mydomain.com\`.
- `www.mydomain.com` is then **no longer renewed**. Its old folder stays on disk, but nothing updates it and the certificate expires after about 90 days. The installer warns about this when the main domain changes.
- The one.com domain can stay `mydomain.com`, because both hostnames belong to that zone.

To keep several hostnames working, enter them all in the same run, for example `www.mydomain.com, blog.mydomain.com` (or `-Domain www.mydomain.com,blog.mydomain.com`). They are then covered by one certificate. Adding or removing a domain changes the domain list, so the next run orders a new certificate that matches it. Keep the existing domains in the list when you add a new one.

- `Setup/Scripts/Invoke-Certificate.ps1 -Environment Production|Staging` does the renewal. Exit code `0` means OK, `1` means failure and `2` means the certificate is OK but a hook failed.
- After a production certificate changes, every `*.ps1` in `C:\Certificate\Hooks` runs with `CERT_*` environment variables. Use a hook to deploy to WAMP/Apache, IIS, nginx and similar (see `Setup/Hooks/README.txt` and the example hook).
- The result of the last run is in `C:\Certificate\STATUS.txt`. Logs are in `C:\Certificate\Logs`.
- If a Posh-ACME update puts a new module version in a new folder, the renewal copies the plugin into it automatically.

The scripts in the `Legacy` folder are the earlier manual setup. They still work. The installer offers to disable their scheduled tasks and archive old copies in `C:\Certificate`.

## What is in this folder

- `Setup/` — automated installation package (see above)
- `Legacy/` — the earlier manual setup (the scripts and notes below)
- `Setup/Scripts/OneCom.ps1` — custom Posh-ACME DNS-01 plugin for one.com. Creates and removes the `_acme-challenge` TXT record through one.com's DNS API. Must be copied into the Posh-ACME `Plugins` folder (see below)
- `Legacy/save-onecom-credential.ps1` — stores the one.com credential securely with Windows DPAPI
- `Legacy/one-staging-test.ps1` — **manual** staging validation flow
- `Legacy/one-production-test.ps1` — **manual**, guarded production issuance flow
- `Legacy/one-staging.ps1` — **automated** staging run for Task Scheduler
- `Legacy/one-production.ps1` — **automated** production issuance/renewal for Task Scheduler, including deployment to WAMP and Apache restart
- `Legacy/New PC configuration.txt` — manual setup notes for a new Windows PC


## Legacy scripts: manual vs. automated

All scripts in this section are in the `Legacy` folder.

| Script | Server | Run by | Confirmation | Deploys to WAMP | Output |
|---|---|---|---|---|---|
| `one-staging-test.ps1` | `LE_STAGE` | Person | No | No | Console |
| `one-production-test.ps1` | `LE_PROD` | Person | Yes (type `PROD`) | No | Console |
| `one-staging.ps1` | `LE_STAGE` | Task Scheduler | No | No | Log file + exit code |
| `one-production.ps1` | `LE_PROD` | Task Scheduler | No | Yes | Log file + exit code |



## Notes

- The credential file is stored under `%LOCALAPPDATA%\Posh-ACME\Secrets\OneComCredential.xml`.
- Do not commit the generated XML file to Git.
- Let's Encrypt production is rate limited (including 5 failed authorisations per account/hostname/hour). Don't run the production scripts repeatedly "just to be sure".
- one.com uses a DNS TTL of 3600, so propagation is slow. If validation times out, raise `-DnsSleep`. Don't change the plugin.

Hooks - kør dine egne scripts, når certifikatet er fornyet
==========================================================

Alle *.ps1-filer i denne mappe køres automatisk (i alfabetisk rækkefølge),
når produktionscertifikatet er blevet fornyet og kopieret til
C:\Certificate\Certificates\<domæne>\.

Brug et hook til fx at:
  - kopiere certifikatet videre til en webserver (Apache/WAMP, nginx, IIS ...)
  - genstarte en Windows-tjeneste, så den bruger det nye certifikat
  - importere certifikatet i Windows' certifikatlager

Kom i gang
----------
1. Kopiér "Eksempel-kopier-og-genstart.ps1.example" og omdøb kopien,
   så den ender på .ps1, fx "10-wamp.ps1".
   (Filer, der ikke ender på .ps1, køres ikke.)
2. Ret indstillingerne øverst i filen.
3. Test hooket med det samme (som administrator i PowerShell):

     C:\Certificate\Scripts\Invoke-Certificate.ps1 -Environment Production -RunHooks

   Kommandoen fornyer kun certifikatet, hvis det er nødvendigt, men kører
   altid hooks. Se resultatet i C:\Certificate\STATUS.txt og Logs-mappen.

Tip: Start filnavnet med et tal (10-, 20-, ...) for at styre rækkefølgen.

Oplysninger, som hooket får
---------------------------
Hooket køres i sin egen PowerShell-proces med administratorrettigheder og
får disse miljøvariabler (læs dem med fx $env:CERT_FULLCHAIN):

  CERT_DOMAIN      Hoveddomænet, fx shop.example.dk
  CERT_DOMAINS     Alle domæner, adskilt af komma
  CERT_DIR         Mappen med certifikatfilerne
  CERT_FULLCHAIN   ...\fullchain.cer  (certifikat + mellemcertifikater)
  CERT_KEY         ...\cert.key       (privat nøgle)
  CERT_CERT        ...\cert.cer       (kun certifikatet)
  CERT_CHAIN       ...\chain.cer      (kun mellemcertifikater)
  CERT_PFX         ...\cert.pfx       (PFX, adgangskode: poshacme)
  CERT_PFX_FULL    ...\fullchain.pfx  (PFX inkl. kæde, adgangskode: poshacme)
  CERT_THUMBPRINT  Certifikatets thumbprint
  CERT_NOTAFTER    Udløbstidspunkt (yyyy-MM-dd HH:mm:ss)

Regler
------
- Exitkode 0 betyder OK. Alt andet (eller en ufanget fejl) tæller som fejl.
  Brug $ErrorActionPreference = 'Stop' og "exit 1" ved fejl.
- Et hook må højst køre i 5 minutter (HookTimeoutSeconds i config.json).
- Hooket må ikke vente på input fra brugeren - der sidder ingen ved skærmen.
- Fejler et hook, er certifikatet stadig fornyet. Kørslen får exitkode 2,
  og STATUS.txt viser, at et hook fejlede. Hooks køres igen ved næste
  fornyelse - eller manuelt med -RunHooks som vist ovenfor.
- Mappen er beskyttet, så kun administratorer og certifikatbrugeren kan
  lægge filer her. Læg aldrig scripts her, som du ikke stoler på.

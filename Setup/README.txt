Let's Encrypt-certifikat via one.com
====================================

Denne mappe indeholder alt om certifikatet på denne PC. Certifikatet
fornyes automatisk hver nat (når det er nødvendigt) af Opgavestyring.


HVOR ER CERTIFIKATET?
---------------------
  Certificates\<domæne>\

    fullchain.cer   Certifikat + mellemcertifikater. Det, de fleste
                    webservere skal bruge (Apache SSLCertificateFile,
                    nginx ssl_certificate).
    cert.key        Privat nøgle (Apache SSLCertificateKeyFile,
                    nginx ssl_certificate_key). HOLD DEN HEMMELIG.
    cert.cer        Kun selve certifikatet.
    chain.cer       Kun mellemcertifikaterne.
    cert.pfx        Certifikat + nøgle til Windows/IIS (adgangskode: poshacme).
    fullchain.pfx   Som cert.pfx, inkl. mellemcertifikater.
    info.txt        Domæner, udløbsdato m.m.

  Filerne opdateres automatisk ved fornyelse - med de samme filnavne.
  Peg derfor dine programmer direkte på filerne her, eller brug et hook
  (se nedenfor) til at kopiere dem videre.


VIRKER DET?
-----------
  Åbn STATUS.txt. Den viser seneste kørsel, resultat og udløbsdato.
  Ved fejl: se den nyeste fil i Logs\.

  Certifikatet fornyes ca. 30 dage før udløb. Viser STATUS.txt en
  udløbsdato under 14 dage ude i fremtiden, er der noget galt.


MAPPER OG FILER
---------------
  Certificates\   Certifikaterne (se ovenfor).
  Hooks\          Dine egne scripts, der køres efter fornyelse. Se Hooks\README.txt.
  Logs\           Logfiler (slettes automatisk efter 30 dage).
  Scripts\        Programfilerne. Ret ikke i dem - de overskrives ved geninstallation.
  config.json     Domæner, e-mail og indstillinger. Ret dem ved at køre Install.cmd igen.
  STATUS.txt      Resultatet af seneste fornyelse.


ALMINDELIGE OPGAVER
-------------------
  Ændre domæner, e-mail eller one.com-adgangskode:
    Kør Install.cmd fra installationspakken igen. Tryk Enter for at
    beholde de nuværende værdier.

  Forny/kontrollér nu:
    Åbn Opgavestyring (Task Scheduler) > Opgavestyringsbibliotek >
    Certificate > højreklik "Fornyelse (produktion)" > Kør.
    Se derefter STATUS.txt.

  Efter opdatering af Posh-ACME:
    Intet. Fornyelsen kopierer selv OneCom-plugin'et ind i den nye version.

  Ændret Windows-adgangskode:
    Kør Install.cmd igen, så de planlagte opgaver får den nye adgangskode.


VIGTIGT
-------
  - Opsætningen hører til den Windows-bruger, der installerede den.
    one.com-adgangskoden er krypteret, så kun denne bruger på denne PC
    kan læse den. Flyttes til en ny PC: kør Install.cmd på den nye PC.
  - To-faktor-login på one.com-kontoen understøttes ikke.
  - Let's Encrypt begrænser antallet af forsøg. Kør ikke fornyelse med
    tvang (-Force) igen og igen "for en sikkerheds skyld".

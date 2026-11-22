# Gib Vid

<img src="GibVid/Resources/Assets.xcassets/AppIcon.appiconset/icon.png" width="96" height="96" alt="Icône de Gib Vid, un photogramme plié">

Gib Vid enregistre une vidéo dans Photos à partir d’un lien copié. L’iPhone contacte directement le site de la vidéo, télécharge les pistes et les assemble sur l’appareil. L’application fonctionne sans compte Gib Vid et sans serveur intermédiaire.

## Installer sur son iPhone

Il faut un Mac avec Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Python 3.10 ou ultérieur avec pip, et un iPhone sous iOS 18 ou ultérieur. La première compilation télécharge le runtime Python et les paquets depuis GitHub et PyPI.

1. Récupère les sources et ouvre un terminal à la racine du projet. Si tu utilises Homebrew, la commande `brew install xcodegen` installe XcodeGen.
2. Prépare les dépendances et génère le projet Xcode.

   ```sh
   ./scripts/fetch_deps.sh
   xcodegen generate
   open GibVid.xcodeproj
   ```

3. Dans Xcode, sélectionne la cible **GibVid**, puis **Signing & Capabilities**. Choisis ton équipe Apple dans **Team** et remplace `org.example.GibVid` par un **Bundle Identifier** unique. Si aucune équipe n’apparaît, ajoute ton compte Apple dans les réglages de Xcode.
4. Branche ton iPhone, sélectionne-le comme destination et lance l’app avec **⌘R**. Active le mode développeur sur l’iPhone si Xcode le demande.

Le projet Xcode est généré. Pour conserver tes réglages après un nouvel appel à `xcodegen generate`, reporte ton identifiant et ton équipe dans ta copie locale de [project.yml](project.yml).

## Enregistrer une vidéo

1. Copie le lien d’une vidéo que tu as le droit de télécharger.
2. Ouvre Gib Vid, touche le grand bouton et autorise l’ajout à Photos au premier téléchargement.
3. Retrouve la vidéo dans Photos une fois l’enregistrement terminé.

Avec l’app Raccourcis, l’action **Ouvrir les URL** avec `gibvid://` lance le téléchargement du lien copié. Pour transmettre un lien directement, utilise `gibvid://?url=<URL encodée>`.

La prise en charge des sites dépend de yt-dlp et des formats que Photos peut importer. Les directs, les publications composées uniquement de photos et les vidéos qui exigent une connexion au site ne sont pas pris en charge.

## Compiler pour le simulateur

Après avoir installé un runtime iOS Simulator dans Xcode, exécute les commandes suivantes à la racine d’une copie fraîche. Cette compilation utilise la signature locale du simulateur.

```sh
./scripts/fetch_deps.sh
xcodegen generate
xcodebuild -project GibVid.xcodeproj -scheme GibVid -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
```

## Fonctionnement

- **Extraction** — [yt-dlp](https://github.com/yt-dlp/yt-dlp) tourne dans [Python pour iOS](https://github.com/beeware/Python-Apple-support). Le [pont C](GibVid/Bridge/GibBridge.c) relie Swift au [moteur Python](python/app/gibvid.py).
- **JavaScript** — le [fournisseur yt-dlp](python/app/gibvid_jsc.py) utilise JavaScriptCore sur l’iPhone.
- **Assemblage** — Gib Vid peut [remettre en forme les MP4 fragmentés](python/app/gibvid_mp4.py) et [réunir les pistes audio et vidéo](GibVid/Media/VideoAssembler.swift) avec AVFoundation.
- **Mises à jour** — la compilation installe les [versions embarquées](scripts/requirements-ios.txt). Sur l’iPhone, l’app consulte aussi PyPI au démarrage si sa dernière vérification remonte à plus de 12 heures. Elle vérifie l’empreinte SHA-256 des paquets récupérés. Toucher le numéro de version lance une vérification manuelle.

## Licence

Le code et l’icône de Gib Vid sont distribués sous [licence MIT](LICENSE). Python, yt-dlp, yt-dlp-ejs, certifi et leurs composants conservent leurs licences respectives.

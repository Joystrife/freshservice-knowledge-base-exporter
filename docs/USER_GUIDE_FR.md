# Guide d'utilisation — Freshservice Knowledge Base Exporter v3.3

## 1. Objectif

L'application PowerShell exporte les articles Freshservice **Solutions / Knowledge Base** au format **HTML** et **JSON**, avec un inventaire **CSV**, les référentiels de catégories et de dossiers, et un journal d'exécution.

Deux modes d'acquisition sont disponibles :

- **Automatique** : récupère le dernier inventaire généré par un **Data Export Analytics** planifié.
- **Manuel** : utilise un reporting Freshservice local au format **CSV** ou **XLSX**.

Dans les deux cas, l'inventaire fournit les identifiants. Le contenu des articles est ensuite récupéré individuellement par API.

## 2. Prérequis

- Windows et **Windows PowerShell 5.1**.
- Connectivité au tenant Freshservice.
- Clé API d'un compte autorisé à consulter les articles concernés.
- En mode automatique, un Data Export **Solutions** planifié et déjà exécuté au moins une fois.
- En mode manuel, un fichier CSV ou XLSX possédant une colonne **ID**.

Aucun droit d'administrateur Windows n'est nécessaire pour l'utilisation habituelle. Les règles de sécurité de l'organisation restent applicables.

## 3. Lancement

Placer `Freshservice-KnowledgeBase-Exporter.ps1` sur le poste, puis exécuter :

```powershell
.\Freshservice-KnowledgeBase-Exporter.ps1
```

Dans l'interface :

1. Indiquer le domaine Freshservice, par exemple `yourcompany.freshservice.com`.
2. Saisir la clé API.
3. Conserver `X` dans le champ de mot de passe Basic Auth ; **ne pas saisir le mot de passe personnel**.
4. Choisir le mode automatique ou manuel.
5. Choisir le dossier de destination avec **Parcourir**.
6. Cliquer sur **Lancer l'export** et consulter le bilan final.

## 4. Configuration du mode automatique

Dans Freshservice : **Analytics → Settings → Data Export → Create Export**.

- **Module Name** : `Solutions`.
- **Schedule** : fréquence adaptée à la fraîcheur attendue, par exemple `Daily`.
- **Workspace filter** : choisir les workspaces autorisés.
- **Basic filters** : vérifier qu'ils ne suppriment pas des articles attendus.
- **Receive At** : `API`.
- **Choose fields** : `ID` obligatoire ; `Title`, `Type`, `Status`, `Author`, `Category`, `Folder` et les dates utiles en complément.

Enregistrer la programmation, puis copier l'**API URL** générée vers le champ **URL d'export Analytics** de l'application.

L'application ne déclenche pas une nouvelle génération du Data Export : elle lit le **dernier fichier produit**. L'inventaire peut donc être plus ancien que l'exécution de PowerShell.

L'URL d'export est sensible et ne doit pas être publiée.

## 5. Mode manuel

Sélectionner **Manuel — choisir un fichier CSV ou XLSX**, puis sélectionner un reporting du module Solutions comportant une colonne **ID**.

L'application retire les ID invalides, déduplique la liste et utilise ensuite le même moteur d'extraction que le mode automatique.

## 6. Fonctionnement technique

1. Lecture du CSV/XLSX manuel ou téléchargement du dernier inventaire Analytics.
2. Détection de la colonne `ID` et déduplication.
3. Lecture des catégories et dossiers Freshservice.
4. Pour chaque ID, exécution d'un appel API individuel.
5. Reconstruction du classement par catégorie/dossier à partir des métadonnées disponibles.
6. Génération des fichiers HTML, JSON, inventaires et logs.

Principaux endpoints :

```text
GET /api/v2/solutions/categories
GET /api/v2/solutions/folders
GET /api/v2/solutions/articles/{article_id}
```

Le nombre d'articles exportables dépend des ID présents dans le rapport et des droits de lecture du compte API. Aucun nombre d'articles n'est codé en dur.

## 7. Fichiers générés

Chaque export crée un répertoire horodaté `Freshservice-KB-Report-Export-...` contenant notamment :

```text
Freshservice-KB-Report-Export-.../
├── Articles/
│   └── <Categorie>/
│       └── <Dossier>/
│           ├── <ID>_<Titre>.html
│           └── <ID>_<Titre>.json
├── source-deduplicated.csv
├── categories.json
├── folders.json
├── articles-clean.csv
├── articles-complete.json
├── export.log
└── export-errors.csv       (si erreurs)
```

Le fichier `articles-clean.xlsx` est facultatif : sa création dépend de la disponibilité de Microsoft Excel.

Lorsque les métadonnées ne permettent pas de résoudre un dossier ou une catégorie, le script conserve les articles exportés dans un classement de secours plutôt que d'inventer des identifiants.

## 8. Préférences locales

L'application peut mémoriser le domaine, le mode, le dossier de destination et l'URL Analytics ; la mémorisation de la clé API est **optionnelle**.

Emplacement de la version GitHub générique :

```text
%LOCALAPPDATA%\Freshservice\KnowledgeBaseExport\settings.json
```

Les champs sensibles sont enregistrés avec `ConvertFrom-SecureString` et la protection Windows associée au compte utilisateur (DPAPI). La configuration ne doit pas être copiée entre utilisateurs ou publiée dans un dépôt.

Le fait de désactiver cette option n'empêche pas un export ponctuel.

## 9. Messages et dépannage

- **Champs obligatoires manquants** : compléter les champs nommés dans le message.
- **Schedule not run yet** : attendre la première génération du Data Export programmé.
- **HTTP 401 / 403** : vérifier authentification, autorisations et accès au rapport ou à l'article.
- **Colonne ID absente** : vérifier le format et les champs du fichier source.
- **XLSX non généré** : utiliser `articles-clean.csv`.
- **Échec d'un article** : consulter `export.log` et `export-errors.csv`.
- **Préférences non enregistrées** : l'extraction peut continuer sans sauvegarde des préférences.

Pour vérifier un traitement complet, rapprocher les ID uniques de l'inventaire, les articles réellement exportés et les éventuels échecs signalés.

## 10. Sécurité et maintenance

- Limiter l'export au périmètre autorisé.
- Ne jamais ajouter les contenus exportés, clés API, URLs Analytics ni `settings.json` au dépôt GitHub.
- Préserver la colonne `ID` du Data Export lors d'une modification de configuration.
- Vérifier la fréquence du rapport et les droits du compte API.
- Vérifier le résultat d'une extraction après toute modification de l'export Analytics ou du script.

## 11. Documentation officielle

- [Freshworks — Scheduled Data Export](https://support.freshservice.com/support/solutions/articles/238958-scheduled-data-export)
- [Freshservice API](https://api.freshservice.com/)

Ce projet est un utilitaire indépendant, non affilié à Freshworks.

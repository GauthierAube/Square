# Square : journal des modifications

Les dernières modifications sont en haut.

## 13 novembre 2026 : la vidéo en plein écran de Side

- Quand Side sort une vidéo YouTube de son tiroir en plein écran, Square range sa fenêtre comme celle d'une application : grille, carrousel, ⌘1 à ⌘9, écran partagé. Les autres fenêtres de Side restent ignorées.
- Fermer cette case (croix, deux doigts vers le haut) ramène la vidéo dans le tiroir au lieu de quitter Side.
- Carrousel à quatre doigts : les cartes voisines ne sont plus transparentes.
- Coin actif : quand Side est ouvert, c'est lui qui gère le coin de la grille (avec ses propres coins actifs). Le réglage de Square est alors remplacé par un bouton « Régler dans Side… ».

## 12 novembre 2026 (nuit) : glisser une case entre deux autres

- Dans la grille, lâcher une case dans l'espace entre deux vignettes (ou au bout d'une rangée) la glisse à cet endroit : les autres se poussent. Avant, il ne se passait rien hors d'une vignette.
- Seule la vignette elle-même sert à échanger (au milieu) ou à partager l'écran (sur un bord).

## 12 novembre 2026 (soir) : Square en anglais

- Square s'affiche en anglais sur tout Mac qui n'est pas réglé en français, et reste en français sinon.
- Réglages › Général › Langue : automatique (langue du Mac), français ou English. Square redémarre pour changer de langue.
- Les textes viennent d'un catalogue de traduction Apple (`Localizable.xcstrings`), mis à jour à chaque compilation quand Xcode est installé. Les fichiers compilés (`Resources/en.lproj`) sont gardés dans le dépôt, pour compiler sans Xcode.

## 12 novembre 2026 : première version publique

**La grille**
- Un coin de l'écran (en haut à droite par défaut) ou le raccourci ⌥ Tab affiche toutes les fenêtres en vignettes, sur le fond d'écran flouté. Y revenir referme la grille sur la fenêtre où l'on était.
- Chaque fenêtre garde sa case. Glisser une vignette sur le milieu d'une autre change l'ordre : les autres se poussent, comme sur iPhone.
- Glisser une vignette sur le bord d'une autre partage l'écran entre les deux fenêtres ; à trois ou quatre, elles se répartissent en bandes égales. Les fenêtres réunies n'ont plus qu'une case, on tire leur séparation pour les redimensionner, et on en sort une en la lâchant ailleurs.
- Deux doigts vers le haut sur une case, la croix ou le clic droit ferment l'application. Les autres cases se resserrent en douceur.
- La molette de la souris parcourt les cases en boucle ; un clic, Entrée ou le clic de la molette choisit.

**Le Dock de la grille**
- Une copie du Dock de macOS, avec la loupe au survol, placée en bas, en haut, à gauche ou à droite.
- Son premier bouton ouvre la liste de toutes les applications, avec une recherche : Entrée ajoute au Dock, Suppr en retire.
- Au bout, la corbeille.

**Quatre doigts**
- Un glissement vers la gauche ou la droite passe à la fenêtre voisine. Posé, il fait apparaître un carrousel de cartes qui suit les doigts ; rapide, il change de fenêtre sans rien afficher.

**Les fenêtres**
- Le bouton vert remplit l'écran sans passer en plein écran d'Apple (Maj ou Option + clic gardent le comportement de macOS).
- Chaque nouvelle fenêtre de travail peut s'agrandir toute seule.
- ⌘1 à ⌘9 mènent droit à une fenêtre.

**Le reste**
- Une fenêtre de réglages façon Réglages Système, et une présentation en images à la première ouverture.
- Square se met en retrait pendant une capture d'écran.
- Il accepte des commandes d'autres applications (Mulot, pour les boutons de la souris).

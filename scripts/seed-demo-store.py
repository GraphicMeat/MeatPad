#!/usr/bin/env python3
"""Seed a throwaway MeatPad storage root with the demo board used for marketing shots.

    python3 scripts/seed-demo-store.py --locale de --root /tmp/meatpad-demo-de

Writes the same board in every locale — same board UUID, same column UUIDs, only the
strings change — so one `-meatpad.revealBoard <BOARD_ID>` launch argument works for all
nine captures. Due dates are relative to `--now` so the board always shows one overdue
card, one due today and two upcoming ones, whenever the shots are retaken.
"""
import argparse
import json
import pathlib
from datetime import datetime, timedelta, timezone

BOARD_ID = "3F2B1A64-0C7E-4D51-9E2A-5B8C41D0A7E3"
SECOND_BOARD_ID = "7A19C3D2-6E84-4F0B-8C15-2D93E6B704AF"
TODO_ID = "1C4E7A90-2B65-43D8-9F17-6E0A5C82B4D1"
DOING_ID = "5D80B216-9C3F-4A7E-B052-8F14C6D93E27"
DONE_ID = "9E63F4A8-7D21-4C05-8B39-1A72D5E04C86"
# Board-specific, to show that columns are not fixed to the global three.
BLOCKED_ID = "2B57E9C0-8A34-4D6F-91B8-4C0F7A6E31D5"

# Column names are lifted verbatim from App/Resources/Localizable.xcstrings so a seeded
# store is indistinguishable from one the app seeded itself on first run.
COLUMNS = {
    "en":      ("Todo", "In Progress", "Done"),
    "de":      ("Zu erledigen", "In Arbeit", "Fertig"),
    "es":      ("Por hacer", "En curso", "Hecho"),
    "fr":      ("À faire", "En cours", "Terminé"),
    "it":      ("Da fare", "In corso", "Fatto"),
    "ja":      ("未着手", "進行中", "完了"),
    "ko":      ("할 일", "진행 중", "완료"),
    "pt-BR":   ("A Fazer", "Em Andamento", "Concluído"),
    "zh-Hans": ("待办", "进行中", "已完成"),
}

BLOCKED = {
    "en": "Blocked", "de": "Blockiert", "es": "Bloqueado", "fr": "Bloqué", "it": "Bloccato",
    "ja": "保留", "ko": "보류", "pt-BR": "Bloqueado", "zh-Hans": "受阻",
}

BOARDS = {
    "en":      ("Launch", "Website"),
    "de":      ("Veröffentlichung", "Website"),
    "es":      ("Lanzamiento", "Sitio web"),
    "fr":      ("Lancement", "Site web"),
    "it":      ("Lancio", "Sito web"),
    "ja":      ("リリース", "ウェブサイト"),
    "ko":      ("출시", "웹사이트"),
    "pt-BR":   ("Lançamento", "Site"),
    "zh-Hans": ("发布", "网站"),
}

FOLDERS = {
    "en":      ("Product", "Launch"),
    "de":      ("Produkt", "Veröffentlichung"),
    "es":      ("Producto", "Lanzamiento"),
    "fr":      ("Produit", "Lancement"),
    "it":      ("Prodotto", "Lancio"),
    "ja":      ("製品", "リリース"),
    "ko":      ("제품", "출시"),
    "pt-BR":   ("Produto", "Lançamento"),
    "zh-Hans": ("产品", "发布"),
}

# (title, body, column, due) — due is an offset in hours from --now, or None.
CARDS = {
    "en": [
        ("Draft the release notes", "Mention the new board view and the folding rewrite.", TODO_ID, 72),
        ("Update the website screenshots", None, TODO_ID, None),
        ("Write the launch announcement", None, TODO_ID, 120),
        ("Ask three testers for feedback", None, TODO_ID, 144),
        ("Record a short demo clip", None, TODO_ID, None),
        ("Notarize the signed build", None, DOING_ID, -20),
        ("Write the privacy page copy", "Plain language, no legalese. Say exactly what leaves this Mac: nothing.", DOING_ID, None),
        ("Polish the update banner", None, DOING_ID, None),
        ("Wire up automatic updates", None, DONE_ID, -48),
        ("Translate the interface", None, DONE_ID, None),
        ("Sign the build with Developer ID", None, DONE_ID, None),
        ("Waiting on the notarization ticket", None, DOING_ID, None),
    ],
    "de": [
        ("Release Notes schreiben", "Die neue Board-Ansicht und die überarbeitete Faltung erwähnen.", TODO_ID, 72),
        ("Website-Screenshots aktualisieren", None, TODO_ID, None),
        ("Ankündigung zum Launch schreiben", None, TODO_ID, 120),
        ("Drei Tester um Feedback bitten", None, TODO_ID, 144),
        ("Kurzen Demo-Clip aufnehmen", None, TODO_ID, None),
        ("Signierten Build notarisieren", None, DOING_ID, -20),
        ("Text für die Datenschutzseite schreiben", "Klare Sprache, kein Juristendeutsch. Genau sagen, was diesen Mac verlässt: nichts.", DOING_ID, None),
        ("Update-Banner verfeinern", None, DOING_ID, None),
        ("Automatische Updates einbauen", None, DONE_ID, -48),
        ("Oberfläche übersetzen", None, DONE_ID, None),
        ("Build mit Developer ID signieren", None, DONE_ID, None),
        ("Auf die Notarisierung warten", None, DOING_ID, None),
    ],
    "es": [
        ("Redactar las notas de la versión", "Mencionar la nueva vista de tablero y el plegado reescrito.", TODO_ID, 72),
        ("Actualizar las capturas del sitio web", None, TODO_ID, None),
        ("Escribir el anuncio del lanzamiento", None, TODO_ID, 120),
        ("Pedir opinión a tres probadores", None, TODO_ID, 144),
        ("Grabar un clip de demostración", None, TODO_ID, None),
        ("Notarizar la compilación firmada", None, DOING_ID, -20),
        ("Redactar la página de privacidad", "Lenguaje claro, sin jerga legal. Decir exactamente qué sale de este Mac: nada.", DOING_ID, None),
        ("Pulir el aviso de actualización", None, DOING_ID, None),
        ("Conectar las actualizaciones automáticas", None, DONE_ID, -48),
        ("Traducir la interfaz", None, DONE_ID, None),
        ("Firmar la build con Developer ID", None, DONE_ID, None),
        ("Esperando la notarización", None, DOING_ID, None),
    ],
    "fr": [
        ("Rédiger les notes de version", "Mentionner la nouvelle vue tableau et le pliage réécrit.", TODO_ID, 72),
        ("Mettre à jour les captures du site", None, TODO_ID, None),
        ("Rédiger l'annonce du lancement", None, TODO_ID, 120),
        ("Demander l'avis de trois testeurs", None, TODO_ID, 144),
        ("Enregistrer une courte démo", None, TODO_ID, None),
        ("Faire notariser la version signée", None, DOING_ID, -20),
        ("Rédiger la page confidentialité", "Langage clair, sans jargon juridique. Dire exactement ce qui quitte ce Mac : rien.", DOING_ID, None),
        ("Peaufiner la bannière d'update", None, DOING_ID, None),
        ("Brancher les mises à jour automatiques", None, DONE_ID, -48),
        ("Traduire l'interface", None, DONE_ID, None),
        ("Signer la version avec Developer ID", None, DONE_ID, None),
        ("En attente du ticket de notarisation", None, DOING_ID, None),
    ],
    "it": [
        ("Scrivere le note di rilascio", "Citare la nuova vista bacheca e il ripiegamento riscritto.", TODO_ID, 72),
        ("Aggiornare le schermate del sito", None, TODO_ID, None),
        ("Scrivere l'annuncio del lancio", None, TODO_ID, 120),
        ("Chiedere un parere a tre tester", None, TODO_ID, 144),
        ("Registrare una breve demo", None, TODO_ID, None),
        ("Notarizzare la build firmata", None, DOING_ID, -20),
        ("Scrivere la pagina sulla privacy", "Linguaggio chiaro, niente burocratese. Dire esattamente cosa esce da questo Mac: nulla.", DOING_ID, None),
        ("Rifinire il banner di aggiornamento", None, DOING_ID, None),
        ("Collegare gli aggiornamenti automatici", None, DONE_ID, -48),
        ("Tradurre l'interfaccia", None, DONE_ID, None),
        ("Firmare la build con Developer ID", None, DONE_ID, None),
        ("In attesa della notarizzazione", None, DOING_ID, None),
    ],
    "ja": [
        ("リリースノートを書く", "新しいボード表示と、折りたたみの刷新に触れる。", TODO_ID, 72),
        ("サイトのスクリーンショットを更新", None, TODO_ID, None),
        ("リリース告知を書く", None, TODO_ID, 120),
        ("テスター3人にフィードバックを依頼", None, TODO_ID, 144),
        ("短いデモ動画を撮る", None, TODO_ID, None),
        ("署名済みビルドを公証に出す", None, DOING_ID, -20),
        ("プライバシーページの文章を書く", "平易な言葉で、法律用語は使わない。このMacから何が出ていくのかを正確に書く。何も出ていかない。", DOING_ID, None),
        ("アップデート表示を整える", None, DOING_ID, None),
        ("自動アップデートを組み込む", None, DONE_ID, -48),
        ("インターフェースを翻訳", None, DONE_ID, None),
        ("Developer IDでビルドに署名", None, DONE_ID, None),
        ("公証チケット待ち", None, DOING_ID, None),
    ],
    "ko": [
        ("릴리스 노트 작성", "새 보드 화면과 새로 만든 접기 기능을 언급할 것.", TODO_ID, 72),
        ("웹사이트 스크린샷 업데이트", None, TODO_ID, None),
        ("출시 공지 작성", None, TODO_ID, 120),
        ("테스터 세 명에게 피드백 요청", None, TODO_ID, 144),
        ("짧은 데모 영상 녹화", None, TODO_ID, None),
        ("서명된 빌드 공증 요청", None, DOING_ID, -20),
        ("개인정보 페이지 문구 작성", "쉬운 말로, 법률 용어 없이. 이 Mac에서 나가는 것이 무엇인지 정확히 쓸 것: 아무것도 없다.", DOING_ID, None),
        ("업데이트 배너 다듬기", None, DOING_ID, None),
        ("자동 업데이트 연결", None, DONE_ID, -48),
        ("인터페이스 번역", None, DONE_ID, None),
        ("Developer ID로 빌드 서명", None, DONE_ID, None),
        ("공증 티켓 대기 중", None, DOING_ID, None),
    ],
    "pt-BR": [
        ("Escrever as notas da versão", "Mencionar a nova visão de quadro e a dobra reescrita.", TODO_ID, 72),
        ("Atualizar as capturas do site", None, TODO_ID, None),
        ("Escrever o anúncio do lançamento", None, TODO_ID, 120),
        ("Pedir feedback a três testadores", None, TODO_ID, 144),
        ("Gravar um clipe de demonstração", None, TODO_ID, None),
        ("Notarizar a build assinada", None, DOING_ID, -20),
        ("Escrever a página de privacidade", "Linguagem simples, sem juridiquês. Dizer exatamente o que sai deste Mac: nada.", DOING_ID, None),
        ("Ajustar o aviso de atualização", None, DOING_ID, None),
        ("Conectar as atualizações automáticas", None, DONE_ID, -48),
        ("Traduzir a interface", None, DONE_ID, None),
        ("Assinar a build com Developer ID", None, DONE_ID, None),
        ("Aguardando a notarização", None, DOING_ID, None),
    ],
    "zh-Hans": [
        ("撰写版本说明", "提到新的看板视图和重写的折叠功能。", TODO_ID, 72),
        ("更新网站截图", None, TODO_ID, None),
        ("撰写发布公告", None, TODO_ID, 120),
        ("请三位测试者反馈", None, TODO_ID, 144),
        ("录制简短演示", None, TODO_ID, None),
        ("对已签名的构建进行公证", None, DOING_ID, -20),
        ("撰写隐私页面文案", "用平实的语言，不用法律术语。准确说明什么会离开这台 Mac：什么都不会。", DOING_ID, None),
        ("打磨更新提示", None, DOING_ID, None),
        ("接入自动更新", None, DONE_ID, -48),
        ("翻译界面", None, DONE_ID, None),
        ("用 Developer ID 签名构建", None, DONE_ID, None),
        ("等待公证回执", None, DOING_ID, None),
    ],
}

# Note bodies are never visible in board mode — the sidebar shows only folder names and
# counts — so one filler line per note is enough to make those counts honest.
NOTES_PER_FOLDER = (2, 1)


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def card_uuid(index: int) -> str:
    return f"C0DE0000-0000-4000-8000-{index:012X}"


def note_uuid(index: int) -> str:
    return f"0DEF0000-0000-4000-8000-{index:012X}"


def seed(root: pathlib.Path, locale: str, now: datetime) -> None:
    todo, doing, done = COLUMNS[locale]
    board_name, second_name = BOARDS[locale]
    folders = FOLDERS[locale]

    boards_dir = root / "Boards"
    notes_dir = root / "Notes"
    boards_dir.mkdir(parents=True, exist_ok=True)
    notes_dir.mkdir(parents=True, exist_ok=True)

    index = {
        "boardOrder": [BOARD_ID, SECOND_BOARD_ID],
        "globalColumns": [
            {"id": TODO_ID, "name": todo, "isDone": False, "emoji": "📋"},
            {"id": DOING_ID, "name": doing, "isDone": False, "emoji": "🚧"},
            {"id": DONE_ID, "name": done, "isDone": True, "emoji": "✅"},
        ],
    }
    (boards_dir / "boards.json").write_text(json.dumps(index, ensure_ascii=False, indent=2))

    cards = []
    for i, (title, body, column, due_hours) in enumerate(CARDS[locale]):
        card = {
            "id": card_uuid(i),
            "title": title,
            "columnID": column,
            "created": iso(now - timedelta(days=9 - i)),
            "modified": iso(now - timedelta(hours=6 - i)),
        }
        if body:
            card["body"] = body
        if due_hours is not None:
            card["due"] = iso((now + timedelta(hours=due_hours)).replace(minute=0, second=0, microsecond=0))
        cards.append(card)

    board = {"id": BOARD_ID, "name": board_name, "extraColumns": [], "cards": cards}
    (boards_dir / f"{BOARD_ID}.json").write_text(json.dumps(board, ensure_ascii=False, indent=2))

    second = {"id": SECOND_BOARD_ID, "name": second_name, "extraColumns": [], "cards": []}
    (boards_dir / f"{SECOND_BOARD_ID}.json").write_text(json.dumps(second, ensure_ascii=False, indent=2))

    (notes_dir / "folders.json").write_text(json.dumps(list(folders), ensure_ascii=False, indent=2))
    index_note = 0
    for folder, count in zip(folders, NOTES_PER_FOLDER):
        for _ in range(count):
            uid = note_uuid(index_note)
            title = f"{folder} {index_note + 1}"
            (notes_dir / f"{uid}.txt").write_text(title + "\n")
            sidecar = {
                "id": uid,
                "created": iso(now - timedelta(days=12 - index_note)),
                "modified": iso(now - timedelta(days=2)),
                "cursor": 0,
                "title": title,
                "folder": folder,
            }
            (notes_dir / f"{uid}.json").write_text(json.dumps(sidecar, ensure_ascii=False, indent=2))
            index_note += 1


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--locale", required=True, choices=sorted(COLUMNS))
    parser.add_argument("--root", required=True, type=pathlib.Path)
    parser.add_argument("--now", default=None, help="ISO timestamp the due dates hang off (default: now)")
    args = parser.parse_args()

    now = datetime.fromisoformat(args.now) if args.now else datetime.now()
    seed(args.root, args.locale, now)
    print(f"seeded {args.locale} at {args.root} (board {BOARD_ID})")


if __name__ == "__main__":
    main()

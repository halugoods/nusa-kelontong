#!/usr/bin/env python3
"""
NUSA Multi-Variant APK Builder
Builds all 8 variants sequentially by swapping config files per variant.
"""
import os, sys, shutil, subprocess, re, time, glob

try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

FLUTTER = r"C:\Users\ertyui\flutter\bin\flutter.bat"
BASE_DIR = r"C:\Users\ertyui\ZCodeProject\nusa_kasir"
OUTPUT_DIR = os.path.join(BASE_DIR, "nusa_builds")
CONFIG_FILE = os.path.join(BASE_DIR, "lib", "core", "config", "nusa_config.dart")
GRADLE_FILE = os.path.join(BASE_DIR, "android", "app", "build.gradle.kts")
MANIFEST_FILE = os.path.join(BASE_DIR, "android", "app", "src", "main", "AndroidManifest.xml")
GMS_DIR = os.path.join(BASE_DIR, "android", "app")
ASSETS_ICONS = os.path.join(BASE_DIR, "assets", "icons")
MIPMAP_DIR = os.path.join(BASE_DIR, "android", "app", "src", "main", "res")

# Mipmap density → pixel size
MIPMAP_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

os.makedirs(OUTPUT_DIR, exist_ok=True)

# ── Variant definitions ──
VARIANTS = [
    {
        "id": "kelontong", "name": "NUSA Kelontong", "pkg": "com.nusa.kelontong",
        "product": "nusa-kelontong", "subtitle": "Aplikasi Kasir untuk Toko Kelontong",
        "primary": "0xFFF97316", "dark": "0xFFEA580C", "soft": "0xFFFFF7ED",
        "repo": "halugoods/nusa-kelontong",
        "cat_emoji": {
            "Sembako": "🍚", "Makanan": "🍜", "Minuman": "🥤",
            "Perlengkapan": "🧹", "Lainnya": "📦",
        },
        "cat_gradients": {
            "Sembako": ["Color(0xFFFFEDD5)", "Color(0xFFFED7AA)", "Color(0xFFFFF7ED)"],
            "Makanan": ["Color(0xFFFEF3C7)", "Color(0xFFFDE68A)", "Color(0xFFFEF9C3)"],
            "Minuman": ["Color(0xFFDBEAFE)", "Color(0xFFBFDBFE)", "Color(0xFFEFF6FF)"],
            "Perlengkapan": ["Color(0xFFDCFCE7)", "Color(0xFFBBF7D0)", "Color(0xFFF0FDF4)"],
            "Lainnya": ["Color(0xFFF3E8FF)", "Color(0xFFE9D5FF)", "Color(0xFFFAF5FF)"],
        },
        "cat_icons": {
            "Semua": "Icons.grid_view_rounded",
            "Sembako": "Icons.rice_bowl_rounded",
            "Makanan": "Icons.restaurant_rounded",
            "Minuman": "Icons.local_drink_rounded",
            "Perlengkapan": "Icons.cleaning_services_rounded",
            "Lainnya": "Icons.category_rounded",
        },
        "hidden_menus": ["meja", "laundry_status", "servis", "booking", "resep", "print_order"],
        "hints": {
            "productName": "Cth: Indomie Goreng",
            "productCategory": "Cth: Sembako",
            "barcode": "contoh: 8991002101234",
            "employeeName": "Cth: Budi Santoso",
        },
    },
    {
        "id": "fnb", "name": "NUSA F&B", "pkg": "com.nusa.fnb",
        "product": "nusa-fnb", "subtitle": "Aplikasi Kasir untuk Rumah Makan & Kafe",
        "primary": "0xFFDC2626", "dark": "0xFF991B1B", "soft": "0xFFFEF2F2",
        "repo": "halugoods/nusa-fnb",
        "cat_emoji": {
            "Makanan": "🍜", "Minuman": "🥤", "Snack": "🍿",
            "Menu Utama": "🍽️", "Lainnya": "📦",
        },
        "cat_gradients": {
            "Makanan": ["Color(0xFFFEE2E2)", "Color(0xFFFECACA)", "Color(0xFFFEF2F2)"],
            "Minuman": ["Color(0xFFDBEAFE)", "Color(0xFFBFDBFE)", "Color(0xFFEFF6FF)"],
            "Snack": ["Color(0xFFFEF3C7)", "Color(0xFFFDE68A)", "Color(0xFFFEF9C3)"],
            "Menu Utama": ["Color(0xFFDCFCE7)", "Color(0xFFBBF7D0)", "Color(0xFFF0FDF4)"],
            "Lainnya": ["Color(0xFFF3E8FF)", "Color(0xFFE9D5FF)", "Color(0xFFFAF5FF)"],
        },
        "cat_icons": {
            "Semua": "Icons.grid_view_rounded",
            "Makanan": "Icons.restaurant_rounded",
            "Minuman": "Icons.local_drink_rounded",
            "Snack": "Icons.bakery_dining_rounded",
            "Menu Utama": "Icons.dinner_dining_rounded",
            "Lainnya": "Icons.category_rounded",
        },
        "hidden_menus": ["spreadsheet",
                         "laundry_status", "servis", "booking", "resep", "print_order"],
        "hints": {
            "productName": "Cth: Nasi Goreng Spesial",
            "productCategory": "Cth: Makanan",
            "employeeName": "Cth: Koki Joko",
        },
    },
    {
        "id": "laundry", "name": "NUSA Laundry", "pkg": "com.nusa.laundry",
        "product": "nusa-laundry", "subtitle": "Aplikasi Kasir untuk Usaha Laundry",
        "primary": "0xFFEC4899", "dark": "0xFFDB2777", "soft": "0xFFFDF2F8",
        "repo": "halugoods/nusa-laundry",
        "cat_emoji": {
            "Cuci Kering": "👕", "Cuci Setrika": "✨", "Setrika Only": "🔥",
            "Express": "⚡", "Lainnya": "📦",
        },
        "cat_gradients": {
            "Cuci Kering": ["Color(0xFFDBEAFE)", "Color(0xFFBFDBFE)", "Color(0xFFEFF6FF)"],
            "Cuci Setrika": ["Color(0xFFFEF3C7)", "Color(0xFFFDE68A)", "Color(0xFFFEF9C3)"],
            "Setrika Only": ["Color(0xFFFEE2E2)", "Color(0xFFFECACA)", "Color(0xFFFEF2F2)"],
            "Express": ["Color(0xFFDCFCE7)", "Color(0xFFBBF7D0)", "Color(0xFFF0FDF4)"],
            "Lainnya": ["Color(0xFFF3E8FF)", "Color(0xFFE9D5FF)", "Color(0xFFFAF5FF)"],
        },
        "cat_icons": {
            "Semua": "Icons.grid_view_rounded",
            "Cuci Kering": "Icons.local_laundry_service_rounded",
            "Cuci Setrika": "Icons.auto_awesome_rounded",
            "Setrika Only": "Icons.whatshot_rounded",
            "Express": "Icons.bolt_rounded",
            "Lainnya": "Icons.category_rounded",
        },
        "hidden_menus": ["promo",
                         "meja", "servis", "booking", "resep", "print_order"],
        "hints": {
            "productName": "Cth: Cuci Kering Lipat",
            "productCategory": "Cth: Layanan",
            "employeeName": "Cth: Tika",
        },
    },
    {
        "id": "bengkel", "name": "NUSA Bengkel", "pkg": "com.nusa.bengkel",
        "product": "nusa-bengkel", "subtitle": "Aplikasi Kasir untuk Bengkel & Otomotif",
        "primary": "0xFFEAB308", "dark": "0xFFCA8A04", "soft": "0xFFFEF9C3",
        "repo": "halugoods/nusa-bengkel",
        "cat_emoji": {
            "Oli": "🛢️", "Ban": "🛞", "Servis": "🔧",
            "Sparepart": "⚙️", "Lainnya": "📦",
        },
        "cat_gradients": {
            "Oli": ["Color(0xFFF3F4F6)", "Color(0xFFE5E7EB)", "Color(0xFFF9FAFB)"],
            "Ban": ["Color(0xFFDBEAFE)", "Color(0xFFBFDBFE)", "Color(0xFFEFF6FF)"],
            "Servis": ["Color(0xFFFEF3C7)", "Color(0xFFFDE68A)", "Color(0xFFFEF9C3)"],
            "Sparepart": ["Color(0xFFDCFCE7)", "Color(0xFFBBF7D0)", "Color(0xFFF0FDF4)"],
            "Lainnya": ["Color(0xFFF3E8FF)", "Color(0xFFE9D5FF)", "Color(0xFFFAF5FF)"],
        },
        "cat_icons": {
            "Semua": "Icons.grid_view_rounded",
            "Oli": "Icons.oil_barrel_rounded",
            "Ban": "Icons.tire_repair_rounded",
            "Servis": "Icons.build_rounded",
            "Sparepart": "Icons.settings_rounded",
            "Lainnya": "Icons.category_rounded",
        },
        "hidden_menus": ["meja", "laundry_status", "booking", "resep", "print_order"],
        "hints": {
            "productName": "Cth: Ganti Oli Mesin",
            "productCategory": "Cth: Servis",
            "employeeName": "Cth: Mekanik Andi",
        },
    },
    {
        "id": "salon", "name": "NUSA Salon", "pkg": "com.nusa.salon",
        "product": "nusa-salon", "subtitle": "Aplikasi Kasir untuk Salon & Barbershop",
        "primary": "0xFF3B82F6", "dark": "0xFF2563EB", "soft": "0xFFEFF6FF",
        "repo": "halugoods/nusa-salon",
        "cat_emoji": {
            "Haircut": "✂️", "Coloring": "🎨", "Treatment": "💆",
            "Styling": "💇", "Lainnya": "📦",
        },
        "cat_gradients": {
            "Haircut": ["Color(0xFFFAFAF9)", "Color(0xFFE7E5E4)", "Color(0xFFF5F5F4)"],
            "Coloring": ["Color(0xFFFEF3C7)", "Color(0xFFFDE68A)", "Color(0xFFFEF9C3)"],
            "Treatment": ["Color(0xFFDCFCE7)", "Color(0xFFBBF7D0)", "Color(0xFFF0FDF4)"],
            "Styling": ["Color(0xFFDBEAFE)", "Color(0xFFBFDBFE)", "Color(0xFFEFF6FF)"],
            "Lainnya": ["Color(0xFFF3E8FF)", "Color(0xFFE9D5FF)", "Color(0xFFFAF5FF)"],
        },
        "cat_icons": {
            "Semua": "Icons.grid_view_rounded",
            "Haircut": "Icons.content_cut_rounded",
            "Coloring": "Icons.palette_rounded",
            "Treatment": "Icons.spa_rounded",
            "Styling": "Icons.face_rounded",
            "Lainnya": "Icons.category_rounded",
        },
        "hidden_menus": ["cabang",
                         "meja", "laundry_status", "servis", "resep", "print_order"],
        "hints": {
            "productName": "Cth: Potong Rambut",
            "productCategory": "Cth: Layanan",
            "employeeName": "Cth: Hair Stylist Rina",
        },
    },
    {
        "id": "apotek", "name": "NUSA Apotek", "pkg": "com.nusa.apotek",
        "product": "nusa-apotek", "subtitle": "Aplikasi Kasir untuk Apotek & Farmasi",
        "primary": "0xFF10B981", "dark": "0xFF059669", "soft": "0xFFECFDF5",
        "repo": "halugoods/nusa-apotek",
        "cat_emoji": {
            "Obat Bebas": "💊", "Obat Resep": "📋", "Vitamin": "💪",
            "Alkes": "🩺", "Lainnya": "📦",
        },
        "cat_gradients": {
            "Obat Bebas": ["Color(0xFFDCFCE7)", "Color(0xFFBBF7D0)", "Color(0xFFF0FDF4)"],
            "Obat Resep": ["Color(0xFFDBEAFE)", "Color(0xFFBFDBFE)", "Color(0xFFEFF6FF)"],
            "Vitamin": ["Color(0xFFFEF3C7)", "Color(0xFFFDE68A)", "Color(0xFFFEF9C3)"],
            "Alkes": ["Color(0xFFFEE2E2)", "Color(0xFFFECACA)", "Color(0xFFFEF2F2)"],
            "Lainnya": ["Color(0xFFF3E8FF)", "Color(0xFFE9D5FF)", "Color(0xFFFAF5FF)"],
        },
        "cat_icons": {
            "Semua": "Icons.grid_view_rounded",
            "Obat Bebas": "Icons.medication_rounded",
            "Obat Resep": "Icons.description_rounded",
            "Vitamin": "Icons.fitness_center_rounded",
            "Alkes": "Icons.monitor_heart_rounded",
            "Lainnya": "Icons.category_rounded",
        },
        "hidden_menus": ["promo",
                         "meja", "laundry_status", "servis", "booking", "print_order"],
        "hints": {
            "productName": "Cth: Paracetamol 500mg",
            "productCategory": "Cth: Obat",
            "barcode": "contoh: 8991002101234",
            "employeeName": "Cth: Apoteker Dewi",
        },
    },
    {
        "id": "fotocopy", "name": "NUSA Fotocopy", "pkg": "com.nusa.fotocopy",
        "product": "nusa-fotocopy", "subtitle": "Aplikasi Kasir untuk Fotocopy & Percetakan",
        "primary": "0xFF8B5CF6", "dark": "0xFF7C3AED", "soft": "0xFFF5F3FF",
        "repo": "halugoods/nusa-fotocopy",
        "cat_emoji": {
            "Print": "🖨️", "Banner & Spanduk": "🪧", "Kartu Nama & Undangan": "💌",
            "Stiker & Label": "🏷️", "Jilid & Laminating": "📚", "ATK": "✏️", "Lainnya": "📦",
        },
        "cat_gradients": {
            "Print": ["Color(0xFFF3E8FF)", "Color(0xFFE9D5FF)", "Color(0xFFFAF5FF)"],
            "Banner & Spanduk": ["Color(0xFFDBEAFE)", "Color(0xFFBFDBFE)", "Color(0xFFEFF6FF)"],
            "Kartu Nama & Undangan": ["Color(0xFFFCE7F3)", "Color(0xFFFBCFE8)", "Color(0xFFFDF2F8)"],
            "Stiker & Label": ["Color(0xFFFEF3C7)", "Color(0xFFFDE68A)", "Color(0xFFFEF9C3)"],
            "Jilid & Laminating": ["Color(0xFFDCFCE7)", "Color(0xFFBBF7D0)", "Color(0xFFF0FDF4)"],
            "ATK": ["Color(0xFFEDE9FE)", "Color(0xFFDDD6FE)", "Color(0xFFF5F3FF)"],
            "Lainnya": ["Color(0xFFFEE2E2)", "Color(0xFFFECACA)", "Color(0xFFFEF2F2)"],
        },
        "cat_icons": {
            "Semua": "Icons.grid_view_rounded",
            "Print": "Icons.print_rounded",
            "Banner & Spanduk": "Icons.flag_rounded",
            "Kartu Nama & Undangan": "Icons.credit_card_rounded",
            "Stiker & Label": "Icons.label_rounded",
            "Jilid & Laminating": "Icons.book_rounded",
            "ATK": "Icons.edit_rounded",
            "Lainnya": "Icons.category_rounded",
        },
        "hidden_menus": ["cabang",
                         "meja", "laundry_status", "servis", "booking", "resep"],
        "hints": {
            "productName": "Cth: Cetak Dokumen A4",
            "productCategory": "Cth: Cetak",
            "employeeName": "Cth: Operator Fajar",
        },
    },
    {
        "id": "servis", "name": "NUSA Servis", "pkg": "com.nusa.servis",
        "product": "nusa-servis", "subtitle": "Aplikasi Kasir untuk Jasa Servis",
        "primary": "0xFF152C63", "dark": "0xFF0F1E47", "soft": "0xFFDBEAFE",
        "repo": "halugoods/nusa-servis",
        "cat_emoji": {
            "Servis Umum": "🛠️", "Elektronik": "📺", "Pijat & Spa": "💆",
            "Kebersihan": "🧹", "Lainnya": "📦",
        },
        "cat_gradients": {
            "Servis Umum": ["Color(0xFFF3F4F6)", "Color(0xFFE5E7EB)", "Color(0xFFF9FAFB)"],
            "Elektronik": ["Color(0xFFDBEAFE)", "Color(0xFFBFDBFE)", "Color(0xFFEFF6FF)"],
            "Pijat & Spa": ["Color(0xFFDCFCE7)", "Color(0xFFBBF7D0)", "Color(0xFFF0FDF4)"],
            "Kebersihan": ["Color(0xFFFEF3C7)", "Color(0xFFFDE68A)", "Color(0xFFFEF9C3)"],
            "Lainnya": ["Color(0xFFF3E8FF)", "Color(0xFFE9D5FF)", "Color(0xFFFAF5FF)"],
        },
        "cat_icons": {
            "Semua": "Icons.grid_view_rounded",
            "Servis Umum": "Icons.handyman_rounded",
            "Elektronik": "Icons.tv_rounded",
            "Pijat & Spa": "Icons.spa_rounded",
            "Kebersihan": "Icons.cleaning_services_rounded",
            "Lainnya": "Icons.category_rounded",
        },
        "hidden_menus": ["meja", "laundry_status", "booking", "resep", "print_order"],
        "hints": {
            "productName": "Cth: Ganti LCD HP",
            "productCategory": "Cth: Servis",
            "employeeName": "Cth: Teknisi Surya",
        },
    },
]


CAT_MAP_TYPES = {
    "_catEmoji": "Map<String, String>",
    "_catGradients": "Map<String, List<Color>>",
    "_catIcons": "Map<String, IconData>",
}


def find_map_lines(lines: list, marker: str) -> tuple:
    """Return (decl_line, open_brace_line, close_brace_line) for a Dart map."""
    for i, line in enumerate(lines):
        stripped = line.strip()
        if marker in stripped and "static" in stripped and "Map<" in stripped and "=" in stripped:
            decl_line = i
            if "{" in stripped:
                open_line = i
            else:
                open_line = i + 1
            # Count nested braces from open_line
            depth = 0
            started = False
            for j in range(open_line, len(lines)):
                for ch in lines[j]:
                    if ch == "{":
                        depth += 1
                        started = True
                    elif ch == "}":
                        depth -= 1
                if started and depth == 0:
                    return (decl_line, open_line, j)
    return None


def replace_map_section(lines: list, marker: str, entry_lines: list) -> list:
    """Replace map entries between { and }, keeping the declaration type."""
    info = find_map_lines(lines, marker)
    if info is None:
        raise ValueError(f"Could not find map section for: {marker}")
    decl_line, open_line, close_line = info

    # Detect original indentation from declaration line
    orig_decl = lines[decl_line]
    base_indent = orig_decl[:len(orig_decl) - len(orig_decl.lstrip())]
    entry_indent = base_indent + "  "

    map_type = CAT_MAP_TYPES.get(marker, "Map<String, dynamic>")
    decl = f"{base_indent}static {map_type} {marker} = {{"

    # Apply entry_indent to each entry line
    indented_entries = []
    for ln in entry_lines:
        indented_entries.append(f"{entry_indent}{ln.strip()}")

    closing = f"{base_indent}}};"
    result = [decl] + indented_entries + [closing]
    return lines[:decl_line] + result + lines[close_line + 1:]


def format_emoji_entries(emoji_dict: dict) -> list:
    """Format catEmoji key-value entries (indentation applied by caller)."""
    return [f"'{k}': '{v}'," for k, v in emoji_dict.items()]


def format_gradient_entries(grad_dict: dict) -> list:
    """Format catGradients key-value entries (indentation applied by caller)."""
    result = []
    for k, colors in grad_dict.items():
        color_str = ", ".join(colors)
        result.append(f"'{k}': [{color_str}],")
    return result


def format_icons_entries(icons_dict: dict) -> list:
    """Format catIcons key-value entries (indentation applied by caller)."""
    return [f"'{k}': {v}," for k, v in icons_dict.items()]


def format_hints_entries(hints_dict: dict) -> list:
    """Format variantHints key-value entries (indentation applied by caller)."""
    return [f"'{k}': '{v}'," for k, v in hints_dict.items()]


def _escape_xml(s: str) -> str:
    """Escape XML special characters (&, <, >, \", ') for safe manifest usage."""
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;") \
            .replace('"', "&quot;").replace("'", "&apos;")


def _escape_whatsapp_path(name: str) -> str:
    """Escape variant name for WhatsApp URL path (spaces → %20)."""
    import urllib.parse
    return urllib.parse.quote(name, safe='')


def setup_logo(variant_id: str):
    """Resize variant app logo into all 5 mipmap densities + copy to splash asset.

    Logo files are named `app_logo_{variant_id} {HEX}.png` (e.g. app_logo_fnb DC2626.png).
    Requires Pillow (`pip install Pillow`) for mipmap resizing.  If Pillow is absent
    the launcher-icon resize is skipped but splash_nusa.png is always copied.
    """
    # Match logo file by pattern: app_logo_{variant_id} *.png
    pattern = os.path.join(ASSETS_ICONS, f"app_logo_{variant_id} *.png")
    matches = glob.glob(pattern)
    if not matches:
        print(f"  ⚠ Logo not found matching: {pattern} — skipping launcher icon & splash")
        return

    logo_src = matches[0]  # pick first match

    # ── Splash asset (always copied, even without Pillow) ──
    splash_dst = os.path.join(ASSETS_ICONS, "splash_nusa.png")
    shutil.copy2(logo_src, splash_dst)
    print(f"  ✓ splash_nusa.png ← {os.path.basename(logo_src)}")

    # ── Mipmap launcher icons (needs Pillow) ──
    if not HAS_PIL:
        print("  ⚠ pip install Pillow missing — skipping launcher icon resize")
        return

    try:
        img = Image.open(logo_src).convert("RGBA")
    except Exception as e:
        print(f"  ⚠ Cannot open logo image: {e}")
        return

    for density, size in MIPMAP_SIZES.items():
        dst_dir = os.path.join(MIPMAP_DIR, f"mipmap-{density}")
        os.makedirs(dst_dir, exist_ok=True)
        dst = os.path.join(dst_dir, "ic_launcher.png")
        resized = img.resize((size, size), Image.LANCZOS)
        resized.save(dst, "PNG")
        print(f"  ✓ ic_launcher.png → mipmap-{density} ({size}×{size})")


def update_config(variant: dict, lite: bool = False):
    """Update all 3 config files for the given variant."""
    v = variant

    # ── 1. Update google-services.json ──
    src = os.path.join(GMS_DIR, f"google-services-{v['id']}.json")
    dst = os.path.join(GMS_DIR, "google-services.json")
    if not os.path.exists(src):
        print(f"  ❌ google-services JSON not found: {src}")
        return False
    shutil.copy2(src, dst)
    print(f"  ✓ google-services.json → {v['id']}")

    # ── 2. Update nusa_config.dart ──
    with open(CONFIG_FILE, "r", encoding="utf-8") as f:
        config = f.read()

    # Single-line replacements (field names are private: _productId, _appSubtitle, etc.)
    config = re.sub(r'(_productId\s*=\s*")[^"]+', rf'\g<1>{v["product"]}', config)
    config = re.sub(r'(_appSubtitle\s*=\s*")[^"]+', rf'\g<1>{v["subtitle"]}', config)
    config = re.sub(r'(_githubRepo\s*=\s*")[^"]+', rf'\g<1>{v["repo"]}', config)
    config = re.sub(r'(_applicationId\s*=\s*")[^"]+', rf'\g<1>{v["pkg"]}', config)
    config = re.sub(r'(_whatsappOrder\s*=\s*")[^"]+', rf'\g<1>https://wa.me/628976280303?text=Halo%2C%20saya%20mau%20beli%20{_escape_whatsapp_path(v["name"])}', config)
    config = re.sub(r'(primaryColor\s*=\s*(?:const\s+)?Color\()[^)]+', rf'\g<1>{v["primary"]}', config)
    config = re.sub(r'(primaryDark\s*=\s*(?:const\s+)?Color\()[^)]+', rf'\g<1>{v["dark"]}', config)
    config = re.sub(r'(primarySoft\s*=\s*(?:const\s+)?Color\()[^)]+', rf'\g<1>{v["soft"]}', config)
    hm = v["hidden_menus"]
    hm_str = "[" + ", ".join("'" + m + "'" for m in hm) + "]"
    config = re.sub(rf"('{v['id']}'\s*:\s*)\[.*?\]", r'\g<1>' + hm_str, config)

    # Category maps: use line-based replacement (regex can't handle nested braces + emoji)
    lines = config.split("\n")
    lines = replace_map_section(lines, "_catEmoji", format_emoji_entries(v["cat_emoji"]))
    lines = replace_map_section(lines, "_catGradients", format_gradient_entries(v["cat_gradients"]))
    lines = replace_map_section(lines, "_catIcons", format_icons_entries(v["cat_icons"]))
    # Field hints per variant (B2) — same line-based approach for the hints map
    lines = replace_map_section(lines, "variantHints", format_hints_entries(v["hints"]))
    config = "\n".join(lines)

    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        f.write(config)
    print(f"  ✓ nusa_config.dart updated")

    # ── 3. Update build.gradle.kts ──
    with open(GRADLE_FILE, "r", encoding="utf-8") as f:
        gradle = f.read()

    gradle = re.sub(r'(namespace\s*=\s*if \(isDevBuild\) "com\.nusa\.dev" else ")[^"]+', rf'\g<1>{v["pkg"]}', gradle)
    gradle = re.sub(r'(applicationId\s*=\s*if \(isDevBuild\) "com\.nusa\.dev" else ")[^"]+', rf'\g<1>{v["pkg"]}', gradle)

    with open(GRADLE_FILE, "w", encoding="utf-8") as f:
        f.write(gradle)
    print(f"  ✓ build.gradle.kts updated")

    # ── 4. Update AndroidManifest.xml ──
    with open(MANIFEST_FILE, "r", encoding="utf-8") as f:
        manifest = f.read()

    manifest = re.sub(r'(android:label=")[^"]+', rf'\g<1>{_escape_xml(v["name"])}', manifest)

    with open(MANIFEST_FILE, "w", encoding="utf-8") as f:
        f.write(manifest)
    print(f"  ✓ AndroidManifest.xml updated")

    # ── 5. Setup app logo → mipmap + splash ──
    setup_logo(v["id"])

    return True


def build_apk(variant_id: str, lite: bool = False):
    """Run Flutter build and reject an output left by an earlier build.
    
    Args:
        variant_id: The variant identifier (e.g. 'fnb', 'laundry').
        lite: If True, build NUSA Lite (offline-only, CLOUD_ENABLED=false).
    """
    apk_src = os.path.join(BASE_DIR, "build", "app", "outputs", "flutter-apk", "app-release.apk")
    try:
        os.remove(apk_src)
    except FileNotFoundError:
        pass
    print("  → Flutter clean...")
    r = subprocess.run([FLUTTER, "clean"], cwd=BASE_DIR, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  ❌ clean failed:\n{r.stderr[-500:]}")
        return False
    print("  → Flutter pub get...")
    r = subprocess.run([FLUTTER, "pub", "get"], cwd=BASE_DIR, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  ❌ pub get failed:\n{r.stderr[-500:]}")
        return False
    mode = "LITE (offline)" if lite else "PRO (cloud)"
    print(f"  → Building release APK [{mode}]...")
    started = time.time()
    # Build command — add --dart-define for Lite builds (offline, no Google/Auth)
    cmd = [FLUTTER, "build", "apk", "--release"]
    if lite:
        cmd.append("--dart-define=CLOUD_ENABLED=false")
        cmd.append("--dart-define=NUSA_LITE=true")
    r = subprocess.run(cmd, cwd=BASE_DIR,
                       capture_output=True, text=True, timeout=2400)
    if r.returncode != 0:
        print(f"  ❌ Build failed:\n{r.stderr[-1000:]}")
        return False
    if not os.path.isfile(apk_src) or os.path.getsize(apk_src) == 0 or os.path.getmtime(apk_src) < started:
        print(f"  ❌ Missing or stale APK output: {apk_src}")
        return False
    return True


def validate_variant(variant: dict):
    """Verify all identity-bearing source files agree before a build."""
    checks = [(CONFIG_FILE, (variant["pkg"], variant["product"], variant["repo"])),
              (GRADLE_FILE, (variant["pkg"],)),
              (MANIFEST_FILE, (_escape_xml(variant["name"],),))]
    for path, values in checks:
        text = open(path, encoding="utf-8").read()
        if not all(value in text for value in values):
            print(f"  ❌ Variant identity validation failed: {path}")
            return False
    return True


def main():
    # v2.2.57+130: Lite-only mode (PRO release jalan terpisah)
    lite_only = "--lite-only" in sys.argv
    if lite_only:
        sys.argv = [a for a in sys.argv if a != "--lite-only"]
    full_only = "--full-only" in sys.argv
    if full_only:
        sys.argv = [a for a in sys.argv if a != "--full-only"]
    requested = set(sys.argv[1:])
    unknown = requested - {v["id"] for v in VARIANTS}
    if unknown:
        print(f"Unknown variant(s): {', '.join(sorted(unknown))}", file=sys.stderr)
        return 2
    variants = [v for v in VARIANTS if not requested or v["id"] in requested]
    backups = [(CONFIG_FILE, CONFIG_FILE + ".orig"),
               (GRADLE_FILE, GRADLE_FILE + ".orig"),
               (MANIFEST_FILE, MANIFEST_FILE + ".orig")]
    orig_gms = os.path.join(GMS_DIR, "google-services.json")
    if os.path.exists(orig_gms):
        backups.append((orig_gms, orig_gms + ".orig"))
    success, failed = [], []
    try:
        for source, backup in backups:
            shutil.copy2(source, backup)
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        # Build each variant twice: PRO (cloud) + LITE (offline)
        # Skip kelontong Lite (already built manually)
        total_builds = len(variants) * (1 if lite_only or full_only else 2)
        skip_variants_lite = set()  # Add variant id here if Lite already built
        build_idx = 0
        for variant in variants:
            vid = variant["id"]
            lite_modes = [False] if full_only else ([True] if lite_only else [False, True])
            for lite in lite_modes:
                build_idx += 1
                mode = "LITE" if lite else "PRO"
                print(f"\n{'='*50}\n  [{build_idx}/{total_builds}] {variant['name']} ({vid}) [{mode}]\n{'='*50}")
                # Output filename: nusa-{vid}.apk (PRO) or nusa-{vid}_lite.apk (LITE)
                apk_name = f"nusa-{vid}_lite.apk" if lite else f"nusa-{vid}.apk"
                apk_dst = os.path.join(OUTPUT_DIR, apk_name)
                # Remove stale APK of same name
                if os.path.exists(apk_dst):
                    os.remove(apk_dst)
                if not update_config(variant) or not validate_variant(variant) or not build_apk(vid, lite=lite):
                    failed.append(f"{vid}_{mode}")
                    continue
                apk_src = os.path.join(BASE_DIR, "build", "app", "outputs", "flutter-apk", "app-release.apk")
                shutil.copy2(apk_src, apk_dst)
                print(f"  APK saved: {apk_dst} ({os.path.getsize(apk_dst) / (1024 * 1024):.1f} MB)")
                success.append(f"{vid}_{mode}")
    finally:
        print("\n  Restoring original config...")
        for source, backup in backups:
            if os.path.exists(backup):
                shutil.copy2(backup, source)
                os.remove(backup)
    print(f"\nBUILD SUMMARY: {len(success)} succeeded, {len(failed)} failed")
    if failed:
        print("Failed: " + ", ".join(failed))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

fn main() {
    // Rebuild the Windows executable resource when generated branding changes.
    println!("cargo:rerun-if-changed=icons");
    tauri_build::build()
}

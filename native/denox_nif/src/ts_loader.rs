use anyhow::Error;
use deno_ast::{
    EmitOptions, MediaType, ParseParams, SourceMapOption, TranspileModuleOptions, TranspileOptions,
};
use deno_core::{
    ModuleLoadResponse, ModuleLoader, ModuleSource, ModuleSourceCode, ModuleSpecifier, ModuleType,
    RequestedModuleType, ResolutionKind,
};

pub struct TsModuleLoader;

impl TsModuleLoader {
    fn media_type_from_specifier(specifier: &ModuleSpecifier) -> MediaType {
        let path = specifier.path();
        if path.ends_with(".ts") {
            MediaType::TypeScript
        } else if path.ends_with(".tsx") {
            MediaType::Tsx
        } else if path.ends_with(".jsx") {
            MediaType::Jsx
        } else if path.ends_with(".mts") {
            MediaType::Mts
        } else if path.ends_with(".cts") {
            MediaType::Cts
        } else if path.ends_with(".json") {
            MediaType::Json
        } else {
            MediaType::JavaScript
        }
    }

    fn needs_transpile(media_type: MediaType) -> bool {
        matches!(
            media_type,
            MediaType::TypeScript
                | MediaType::Tsx
                | MediaType::Jsx
                | MediaType::Mts
                | MediaType::Cts
                | MediaType::Dts
        )
    }

    fn transpile_source(
        specifier: &ModuleSpecifier,
        source: &str,
        media_type: MediaType,
    ) -> Result<String, Error> {
        let parsed = deno_ast::parse_module(ParseParams {
            specifier: specifier.clone(),
            text: source.into(),
            media_type,
            capture_tokens: false,
            scope_analysis: false,
            maybe_syntax: None,
        })?;

        let transpiled = parsed.transpile(
            &TranspileOptions::default(),
            &TranspileModuleOptions::default(),
            &EmitOptions {
                source_map: SourceMapOption::None,
                ..Default::default()
            },
        )?;

        Ok(transpiled.into_source().text)
    }
}

impl ModuleLoader for TsModuleLoader {
    fn resolve(
        &self,
        specifier: &str,
        referrer: &str,
        _kind: ResolutionKind,
    ) -> Result<ModuleSpecifier, Error> {
        deno_core::resolve_import(specifier, referrer).map_err(|e| e.into())
    }

    fn load(
        &self,
        module_specifier: &ModuleSpecifier,
        _maybe_referrer: Option<&ModuleSpecifier>,
        _is_dyn_import: bool,
        _requested_module_type: RequestedModuleType,
    ) -> ModuleLoadResponse {
        let specifier = module_specifier.clone();

        match specifier.scheme() {
            "file" => {
                let path = match specifier.to_file_path() {
                    Ok(p) => p,
                    Err(_) => {
                        return ModuleLoadResponse::Sync(Err(anyhow::anyhow!(
                            "Invalid file URL: {}",
                            specifier
                        )));
                    }
                };

                let source = match std::fs::read_to_string(&path) {
                    Ok(s) => s,
                    Err(e) => {
                        return ModuleLoadResponse::Sync(Err(anyhow::anyhow!(
                            "Failed to read {}: {}",
                            path.display(),
                            e
                        )));
                    }
                };

                let media_type = Self::media_type_from_specifier(&specifier);
                let module_type = if media_type == MediaType::Json {
                    ModuleType::Json
                } else {
                    ModuleType::JavaScript
                };

                let code = if Self::needs_transpile(media_type) {
                    match Self::transpile_source(&specifier, &source, media_type) {
                        Ok(js) => js,
                        Err(e) => {
                            return ModuleLoadResponse::Sync(Err(anyhow::anyhow!(
                                "Transpile error for {}: {}",
                                specifier,
                                e
                            )));
                        }
                    }
                } else {
                    source
                };

                ModuleLoadResponse::Sync(Ok(ModuleSource::new(
                    module_type,
                    ModuleSourceCode::String(code.into()),
                    &specifier,
                    None,
                )))
            }
            scheme => ModuleLoadResponse::Sync(Err(anyhow::anyhow!(
                "Unsupported scheme '{}' in module specifier: {}",
                scheme,
                specifier
            ))),
        }
    }
}

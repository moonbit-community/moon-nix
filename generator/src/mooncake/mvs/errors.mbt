///|
pub suberror ResolveError {
  FetchFailed(url~ : String, detail~ : String)
  ConflictingVersions(
    module_name~ : String,
    conflicts~ : Array[(String, Array[String])]
  )
  ModuleMissing(name~ : String, dependant~ : String)
  NoSatisfiedVersion(name~ : String, dependant~ : String, required~ : String)
}

///|
pub fn describe_error(error : ResolveError) -> String {
  match error {
    FetchFailed(url~, detail~) => "registry index " + url + ": " + detail
    ModuleMissing(name~, dependant~) =>
      "module " + name + " required by " + dependant + " is absent from the registry index"
    NoSatisfiedVersion(name~, dependant~, required~) =>
      "no version of " + name + " satisfies " + required + " (required by " + dependant + ")"
    ConflictingVersions(module_name~, ..) =>
      "incompatible versions of " + module_name + " are required"
  }
}

/// Selects the execution topology, not the quality level of a tutor answer.
enum ExecutionMode {
  /// Host phone performs inference, speech, retrieval, and persistence locally.
  standaloneHost,

  /// Paired tablet delegates heavy work to a host over the local network.
  lanCompanion,

  /// Standalone low-memory device uses the lightweight local model profile.
  lightEdge,
}

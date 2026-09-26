import MLX

/// The host's MLX buffer-pool policy for the SDK backend.
///
/// The SDK leaves MLX's shared buffer pool alone by default, so closing a
/// cleaner drops the model's references without returning the ~2 GB to the
/// system (measured: the process footprint stays put after `closeAndWait()`).
/// The host clears the pool once, after a retiring cleaner has actually
/// released its resources — the same process-global clear the in-app engine
/// already does on unload. Not per generation (`clearBufferCache: true`
/// would clear on every request and every close), and only when no other
/// MLX model is resident: under the SDK backend the in-app engine is never
/// loaded and model variant suggestions are disabled.
enum MLXBufferPool {
    static func releaseCachedBuffers() { Memory.clearCache() }
}

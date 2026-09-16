// Smoke-test shader for ghostty_shader_msl.
vec4 COLOR = vec4(1.0, 0.0, 0.0, 1.0);

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    #if !defined(WEB)
    fragColor = texture(iChannel0, fragCoord.xy / iResolution.xy);
    #endif
    float d = distance(
        fragCoord.xy / iResolution.xy,
        iCurrentCursor.xy / iResolution.xy);
    fragColor = mix(fragColor, COLOR, 1.0 - smoothstep(0.0, 0.2, d));
}

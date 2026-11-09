using Microsoft.Extensions.Caching.Memory;
using System.Net;

namespace PharmaGo.ApiGateway.Middleware
{
    /// <summary>
    /// Mitiga ataques o clientes que incitan fallas reiteradas (HTTP 4xx / 5xx).
    /// Si un cliente acumula un alto volumen de solicitudes fallidas en una ventana de tiempo,
    /// se le aplica una contención temporal devolviendo HTTP 429 Too Many Requests,
    /// evitando saturar los microservicios de backend y la base de datos.
    /// </summary>
    public class FailedRequestsThrottlingMiddleware
    {
        private readonly RequestDelegate _next;
        private readonly IMemoryCache _cache;
        private readonly ILogger<FailedRequestsThrottlingMiddleware> _logger;
        private readonly int _maxFailedRequestsPerMinute;
        private readonly int _penaltyDurationSeconds;

        public FailedRequestsThrottlingMiddleware(
            RequestDelegate next,
            IMemoryCache cache,
            ILogger<FailedRequestsThrottlingMiddleware> logger,
            IConfiguration configuration)
        {
            _next = next;
            _cache = cache;
            _logger = logger;
            _maxFailedRequestsPerMinute = configuration.GetValue<int?>("FailedRequestsThrottling:MaxFailedRequestsPerMinute") ?? 30;
            _penaltyDurationSeconds = configuration.GetValue<int?>("FailedRequestsThrottling:PenaltyDurationSeconds") ?? 15;
        }

        public async Task InvokeAsync(HttpContext context)
        {
            var path = context.Request.Path.Value?.ToLowerInvariant() ?? string.Empty;

            // Ignorar health checks y endpoints de telemetría
            if (path.StartsWith("/health") || path.StartsWith("/metrics") || context.Request.Method == "OPTIONS")
            {
                await _next(context);
                return;
            }

            var clientIp = GetClientIp(context);
            var penaltyKey = $"failed_req_penalty:{clientIp}";

            // 1. Verificar si el cliente está actualmente penalizado por fallas reiteradas
            if (_cache.TryGetValue(penaltyKey, out DateTime penaltyExpiry))
            {
                var remainingSeconds = Math.Max(1, (int)(penaltyExpiry - DateTime.UtcNow).TotalSeconds);
                _logger.LogWarning("Request blocked for client {ClientIp}: throttled due to excessive failed requests. Remaining: {Seconds}s", clientIp, remainingSeconds);

                context.Response.StatusCode = (int)HttpStatusCode.TooManyRequests;
                context.Response.Headers["Retry-After"] = remainingSeconds.ToString();
                context.Response.Headers["X-Throttling-Reason"] = "High volume of failed requests detected";
                await context.Response.WriteAsJsonAsync(new
                {
                    error = "Too Many Requests",
                    message = "Cliente temporalmente suspendido por acumulación excesiva de solicitudes fallidas (patrón de resiliencia).",
                    retryAfterSeconds = remainingSeconds
                });
                return;
            }

            // 2. Ejecutar la llamada al downstream
            await _next(context);

            // 3. Evaluar si la respuesta fue un error atribuible al cliente (HTTP 4xx, excluyendo 429)
            // IMPORTANTE: NO penalizar al cliente por errores del servidor (HTTP 5xx, ej. caídas de microservicios downstream)
            // ni por respuestas que ya son rechazos por limitación de tasa (HTTP 429).
            if (context.Response.StatusCode >= 400 && context.Response.StatusCode < 500 && context.Response.StatusCode != (int)HttpStatusCode.TooManyRequests)
            {
                var now = DateTime.UtcNow;
                var windowKey = $"failed_req_count:{clientIp}:{now:yyyyMMddHHmm}";

                var failureCount = _cache.GetOrCreate(windowKey, entry =>
                {
                    entry.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(1);
                    return 0;
                }) + 1;

                _cache.Set(windowKey, failureCount, TimeSpan.FromMinutes(1));

                if (failureCount >= _maxFailedRequestsPerMinute)
                {
                    var expiry = DateTime.UtcNow.AddSeconds(_penaltyDurationSeconds);
                    _cache.Set(penaltyKey, expiry, TimeSpan.FromSeconds(_penaltyDurationSeconds));
                    _logger.LogWarning("Client {ClientIp} exceeded failed requests threshold ({Count}/{Max}). Throttled for {Seconds}s.",
                        clientIp, failureCount, _maxFailedRequestsPerMinute, _penaltyDurationSeconds);
                }
            }
        }

        private string GetClientIp(HttpContext context)
        {
            if (context.Request.Headers.TryGetValue("X-Forwarded-For", out var forwardedFor))
            {
                var ip = forwardedFor.ToString().Split(',')[0].Trim();
                if (!string.IsNullOrEmpty(ip)) return ip;
            }

            if (context.Request.Headers.TryGetValue("X-Real-IP", out var realIp))
            {
                var ip = realIp.ToString().Trim();
                if (!string.IsNullOrEmpty(ip)) return ip;
            }

            return context.Connection.RemoteIpAddress?.ToString() ?? "unknown";
        }
    }

    public static class FailedRequestsThrottlingMiddlewareExtensions
    {
        public static IApplicationBuilder UseFailedRequestsThrottling(this IApplicationBuilder builder)
        {
            return builder.UseMiddleware<FailedRequestsThrottlingMiddleware>();
        }
    }
}

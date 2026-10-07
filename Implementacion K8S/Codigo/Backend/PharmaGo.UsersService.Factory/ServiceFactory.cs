using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using PharmaGo.UsersService.BusinessLogic;
using PharmaGo.DataAccess;
using PharmaGo.DataAccess.Repositories;
using PharmaGo.Domain.Entities;
using PharmaGo.UsersService.IBusinessLogic;
using PharmaGo.IDataAccess;
using Microsoft.Extensions.Hosting;
using InstrumentationInterface;
using Instrumentation;
using Polly;

namespace PharmaGo.UsersService.Factory
{
    public static class ServiceFactory
    {
        private static readonly Random _jitterRandom = new();

        public static void RegisterBusinessLogicServices(this IServiceCollection serviceCollection, IConfiguration configuration)
        {
            serviceCollection.AddScoped<ILoginManager, LoginManager>();
            serviceCollection.AddScoped<IUsersManager, UsersManager>();
            serviceCollection.AddScoped<IInvitationManager, InvitationManager>();
            serviceCollection.AddScoped<IRoleManager, RoleManager>();
            
            serviceCollection.AddHttpClient<PharmaGo.UsersService.HttpClients.PharmacyServiceClient>(client =>
            {
                var serviceUrl = configuration["ServiceUrls:PharmacyService"] ?? "http://127.0.0.1:5002";
                client.BaseAddress = new Uri(serviceUrl);
                client.Timeout = TimeSpan.FromSeconds(30);
            })
            // Reintento con Equal Jitter: (backoff / 2) + random(0, backoff / 2)
            .AddTransientHttpErrorPolicy(policyBuilder =>
                policyBuilder.WaitAndRetryAsync(
                    retryCount: 3,
                    sleepDurationProvider: attempt =>
                    {
                        double totalBackoff = Math.Pow(2, attempt);
                        double halfBackoff = totalBackoff / 2.0;
                        double jitter = _jitterRandom.NextDouble() * halfBackoff;
                        return TimeSpan.FromSeconds(halfBackoff + jitter);
                    }))
            // Circuit Breaker: 5 fallas consecutivas abren el circuito por 30 segundos
            .AddTransientHttpErrorPolicy(policyBuilder =>
                policyBuilder.CircuitBreakerAsync(
                    handledEventsAllowedBeforeBreaking: 5,
                    durationOfBreak: TimeSpan.FromSeconds(30)));
        }

        public static void RegisterDataAccessServices(this IServiceCollection serviceCollection, IConfiguration configuration)
        {
            serviceCollection.AddScoped<IRepository<User>, UsersRepository>();
            serviceCollection.AddScoped<IRepository<Session>, SessionRepository>();
            serviceCollection.AddScoped<IRepository<Invitation>, InvitationRepository>();
            serviceCollection.AddScoped<IRepository<Role>, RoleRepository>();
            serviceCollection.AddScoped<IRepository<Pharmacy>, PharmacyRepository>();

            serviceCollection.AddDbContext<DbContext, PharmacyGoDbContext>(options =>
            {
                options.UseSqlServer(
                    configuration.GetConnectionString("DefaultConnection"),
                    sqlOptions => { sqlOptions.MigrationsAssembly("PharmaGo.DataAccess"); });
                options.ConfigureWarnings(w =>
                {
                    w.Ignore(RelationalEventId.CommandExecuted);
                    w.Ignore(RelationalEventId.CommandError);
                });
            });
            serviceCollection.AddSingleton<ICustomMetrics, CustomMetrics>();
            serviceCollection.AddSingleton<IStructuredLogger, StructuredLogger>();
        }

        public static IHost MigrateDatabase(this IHost host)
        {
            using (var scope = host.Services.CreateScope())
            {
                var dbContext = scope.ServiceProvider.GetRequiredService<DbContext>();
                dbContext.Database.Migrate();
            }

            return host;
        }

    }
}

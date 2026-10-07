using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using PharmaGo.PharmacyService.BusinessLogic;
using PharmaGo.DataAccess;
using PharmaGo.DataAccess.Repositories;
using PharmaGo.Domain.Entities;
using PharmaGo.PharmacyService.IBusinessLogic;
using PharmaGo.IDataAccess;
using Microsoft.Extensions.Hosting;
using InstrumentationInterface;
using Instrumentation;
using Polly;

namespace PharmaGo.PharmacyService.Factory
{
    public static class ServiceFactory
    {
        private static readonly Random _jitterRandom = new();

        public static void RegisterBusinessLogicServices(this IServiceCollection serviceCollection, IConfiguration configuration)
        {
            serviceCollection.AddScoped<IStockRequestManager, StockRequestManager>();
            serviceCollection.AddScoped<IPurchasesManager, PurchasesManager>();
            serviceCollection.AddScoped<IPharmacyManager, PharmacyManager>();
            serviceCollection.AddScoped<IDrugManager, DrugManager>();
            serviceCollection.AddScoped<IPresentationManager, PresentationManager>();
            serviceCollection.AddScoped<IUnitMeasureManager, UnitMeasureManager>();
            serviceCollection.AddScoped<IExportManager, ExportManager>();
            
            serviceCollection.AddHttpClient<PharmaGo.PharmacyService.HttpClients.UsersServiceClient>(client =>
            {
                var serviceUrl = configuration["ServiceUrls:UsersService"] ?? "http://127.0.0.1:5001";
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
            serviceCollection.AddScoped<IRepository<StockRequest>, StockRequestRepository>();
            serviceCollection.AddScoped<IRepository<Pharmacy>, PharmacyRepository>();
            serviceCollection.AddScoped<IRepository<UnitMeasure>, UnitMeasureRepository>();
            serviceCollection.AddScoped<IRepository<Purchase>, PurchasesRepository>();
            serviceCollection.AddScoped<IRepository<Presentation>, PresentationRepository>();
            serviceCollection.AddScoped<IRepository<Drug>, DrugRepository>();
            serviceCollection.AddScoped<IRepository<PurchaseDetail>, PurchasesDetailRepository>();

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

    }
}

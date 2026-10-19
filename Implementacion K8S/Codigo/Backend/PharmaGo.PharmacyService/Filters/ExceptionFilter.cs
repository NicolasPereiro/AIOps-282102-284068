using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Mvc;
using PharmaGo.Exceptions;
using Microsoft.Data.SqlClient.Server;

namespace PharmaGo.PharmacyService.Filters;
public class ExceptionFilter : IExceptionFilter
{
    private readonly ILogger<ExceptionFilter> _logger;

    public ExceptionFilter(ILogger<ExceptionFilter> logger)
    {
        _logger = logger;
    }

    public void OnException(ExceptionContext context)
    {
        var exception = context.Exception;

        if (exception is ResourceNotFoundException)
        {
            context.Result = new JsonResult(new { Message = exception.Message }) { StatusCode = 404 };
        }
        else if (exception is InvalidResourceException)
        {
            context.Result = new JsonResult(new { Message = exception.Message }) { StatusCode = 400 };
        }
        else if (exception is FormatException)
        {
            context.Result = new JsonResult(new { Message = "Invalid token format" }) { StatusCode = 400 };
        }
        else
        {
            _logger.LogError(exception, "Unhandled exception captured by ExceptionFilter");
            context.Result = new JsonResult(new { Message = exception.Message }) { StatusCode = 500 };
        }

        context.ExceptionHandled = true;
    }
}

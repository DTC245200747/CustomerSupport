using System.ComponentModel.DataAnnotations;

namespace CustomerSupportAI.Models;

public sealed class SupportUser
{
    public int Id { get; set; }

    [Required, MaxLength(100)]
    public string DisplayName { get; set; } = string.Empty;

    [Required, EmailAddress, MaxLength(320)]
    public string Email { get; set; } = string.Empty;

    [Required, MaxLength(320)]
    public string NormalizedEmail { get; set; } = string.Empty;

    [Required]
    public string PasswordHash { get; set; } = string.Empty;

    [Required, MaxLength(20)]
    public string Role { get; set; } = UserRoles.Customer;

    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}
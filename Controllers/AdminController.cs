using CustomerSupportAI.Data;
using CustomerSupportAI.Models;
using CustomerSupportAI.ViewModels;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace CustomerSupportAI.Controllers;

[Authorize(Roles = UserRoles.Admin)]
public sealed class AdminController(
    AppDbContext db,
    IPasswordHasher<SupportUser> passwordHasher) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Users()
    {
        return View(await BuildUsersViewModelAsync(new CreateStaffViewModel()));
    }

    [HttpPost]
    public async Task<IActionResult> CreateStaff([Bind(Prefix = "NewStaff")] CreateStaffViewModel model)
    {
        if (!ModelState.IsValid)
        {
            return View("Users", await BuildUsersViewModelAsync(model));
        }

        var email = model.Email.Trim();
        var normalizedEmail = email.ToUpperInvariant();
        if (await db.Users.AnyAsync(user => user.NormalizedEmail == normalizedEmail))
        {
            ModelState.AddModelError("NewStaff.Email", "Email này đã được đăng ký.");
            return View("Users", await BuildUsersViewModelAsync(model));
        }

        var staff = new SupportUser
        {
            DisplayName = model.DisplayName.Trim(),
            Email = email,
            NormalizedEmail = normalizedEmail,
            Role = UserRoles.Staff
        };
        staff.PasswordHash = passwordHasher.HashPassword(staff, model.TemporaryPassword);
        db.Users.Add(staff);
        await db.SaveChangesAsync();
        TempData["Success"] = $"Đã tạo tài khoản nhân viên cho {staff.Email}.";
        return RedirectToAction(nameof(Users));
    }

    private async Task<AdminUsersViewModel> BuildUsersViewModelAsync(CreateStaffViewModel newStaff)
    {
        var users = await db.Users.OrderBy(user => user.Id).ToListAsync();
        var ticketCounts = await db.Tickets
            .GroupBy(ticket => ticket.CustomerId)
            .Select(group => new { UserId = group.Key, Count = group.Count() })
            .ToDictionaryAsync(item => item.UserId, item => item.Count);

        return new AdminUsersViewModel
        {
            Users = users.Select(user => new UserListItemViewModel
            {
                User = user,
                TicketCount = ticketCounts.GetValueOrDefault(user.Id)
            }).ToList(),
            NewStaff = newStaff
        };
    }
}
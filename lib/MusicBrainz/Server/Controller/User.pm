package MusicBrainz::Server::Controller::User;

use strict;
use warnings;

use base 'Catalyst::Controller';

use MusicBrainz;
use UserPreference;
use UserStuff;

=head1 NAME

MusicBrainz::Server::Controller::User - Catalyst Controller to handle
user authentication and profile management

=head1 DESCRIPTION

The user controller handles users logging in and logging out, the
registration or administration of accounts, and the viewing/updating of
profile pages.

=head1 METHODS

=head2 index

If the user is currently logged in redirect them to their profile page,
otherwise redirect the user to the login page.

=cut

sub index : Private
{
    my ($self, $c) = @_;

    $c->forward('login');
    $c->detach('profile');
}

=head2 login

Display a form allowing users to login. If a POST request is received,
we validate this login data, and attempt to log the user in.

=cut

sub login : Local
{
    my ($self, $c) = @_;

    unless ($c->user_exists)
    {
        use MusicBrainz::Server::Form::User::Login;

        my $form = MusicBrainz::Server::Form::User::Login->new;
        $c->stash->{form} = $form;

        if ($c->form_posted && $form->validate($c->request->parameters))
        {
            my ($username, $password) = ( $form->value("username"),
                                          $form->value("password") );

            if( $c->authenticate({ username => $username,
                                   password => $password }) )
            {
                $c->response->redirect($c->req->referer);
                $c->detach;
            }
            else
            {
                $c->stash->{errors} = ['Username/password combination invalid'];
            }
        }

        $c->stash->{template} = 'user/login.tt';

        # Have to make sure we detach
        $c->detach;
    }
}

=head2 register

Display a form allowing new users to register on the site. When a POST
request is received, we validate the data and attempt to create the
new user.

=cut

sub register : Local
{
    my ($self, $c) = @_;

    use MusicBrainz::Server::Form::User::Register;

    my $form = MusicBrainz::Server::Form::User::Register->new;
    $c->stash->{form} = $form;

    if($c->form_posted && $form->validate($c->request->parameters))
    {
        my $new_user = $c->model('User')->create($form->value('username'),
                                                 $form->value('password'));

        my $email            = $form->value('email');
        my $could_send_email = $new_user->get_user->SendVerificationEmail($email);

        $c->authenticate({ username => $new_user->username,
                           password => $new_user->password });

        $c->detach('registered', $could_send_email, $email);
    }

    $c->stash->{template} = 'user/register.tt';
}

=head2 registered

Called when a user has completed registration. We use this to notify
the user that everything went ok.

=cut

sub registered : Private
{
    my ($self, $c, $couldSend, $email) = @_;

    $c->stash->{emailed} = $couldSend;
    $c->stash->{email}   = $email;

    $c->stash->{template} = 'user/registered.tt';
}

=head2 forgotPassword

Allow users to retrieve their password if they have forgotten it.

This displays a form allowing the user to enter either their username
or email address in. With this data we then attempt to email the user
their password.

=cut

sub forgotPassword : Local
{
    my ($self, $c) = @_;

    use MusicBrainz::Server::Form::User::ForgotPassword;

    my $form = new MusicBrainz::Server::Form::User::ForgotPassword;
    $form->context($c);
    $c->stash->{form} = $form;

    if ($c->form_posted && $form->validate($c->req->params))
    {
        my ($email, $username) = ( $form->value('email'),
                                   $form->value('username') );

        if ($email)
        {
            my $usernames = $c->model('User')->find_by_email($email);
            if(scalar @$usernames)
            {
                foreach $username (@$usernames)
                {
                    my $user = $c->model('User')->load_user({ username => $username });
                    if ($user)
                    {
                        $user->SendPasswordReminder
                            or die "Could not send password reminder";
                    }
                }

                $c->flash->{ok} = "A password reminder has been sent to you. Please check your inbox for more details";
            }
            else
            {
                $c->field('email')->add_error('We could not find any users registered with this email address');
            }
        }
        elsif ($username)
        {
            my $user = $c->model('User')->load_user({ username => $username });
            if ($user)
            {
                $user->get_user->SendPasswordReminder
                    or die "Could not send password reminder";

                $c->flash->{ok} = "A password reminder has been sent to you. Please check your inbox for more details";
            }
        }
    }

    $c->stash->{template} = 'user/forgot.tt';
}

=head2 editProfile

Display a form to allow users to edit their profile, or (if a POST
request is received), update the profile data in the database.

=cut

sub edit_profile : Local
{
    my ($self, $c) = @_;

    $c->forward('login');

    use MusicBrainz::Server::Form::User::EditProfile;

    my $form = new MusicBrainz::Server::Form::User::EditProfile($c->user);
    $c->stash->{form} = $form;

    if ($c->form_posted)
    {
        $c->flash->{ok} = "Your profile has been sucessfully updated"
            if $form->update_from_form ($c->req->params);
    }

    $c->stash->{template} = 'user/edit.tt';
}

=head2 changePassword

Allow users to change their password. This displays a form prompting
for their old password and a new password (with confirmation), which
when use to update the database data when we receive a valid POST request.

=cut

sub change_password : Local
{
    my ($self, $c) = @_;

    $c->forward('login');

    use MusicBrainz::Server::Form::User::ChangePassword;

    my $form = new MusicBrainz::Server::Form::User::ChangePassword;
    $c->stash->{form} = $form;

    if ($c->form_posted && $form->validate($c->req->params))
    {
        if ($form->value('old_password') eq $c->user->password)
        {
            $c->user->get_user->ChangePassword( $form->value('old_password'),
                                                  $form->value('new_password'),
                                                  $form->value('confirm_new_password') );

            $c->flash->{ok} = "Your password has been successfully changed";
        }
        else
        {
            $form->field('old_password')->add_error("Old password is incorrect.");
        }
    }

    $c->stash->{template} = 'user/changePassword.tt';
}

=head2 profile

Display a users profile page.

=cut 

sub profile : Local
{
    my ($self, $c, $user_name) = @_;

    my $user;
    
    if ($c->user_exists)
    {
        $user = $c->user;
    }
    else
    {
        if ($user_name)
        {
            $user = $c->model('User')->load_user({ username => $user_name });
        }
        else
        {
            $c->response->redirect($c->uri_for('/user/login'));
            $c->detach();
        }
    }

    if ($c->user_exists && $c->user->id eq $user->id)
    {
        $c->stash->{viewing_own_profile} = 1;
    }

    die "The user with username '" . $user_name . "' could not be found"
        unless $user;

    $c->stash->{profile} = $user;

    $c->stash->{template} = 'user/profile.tt';
}

=head2 logout

Logout the current user. Has no effect if the user is already logged out.

=cut

sub logout : Local
{
    my ($self, $c) = @_;

    $c->logout;
    $c->response->redirect($c->uri_for('/user/login'));
}

=head2 preferences

Change the users preferences

=cut

sub preferences : Local
{
    my ($self, $c) = @_;

    $c->forward('login');

    my $user  = $c->user;

    use MusicBrainz::Server::Form::User::Preferences;

    my $form = MusicBrainz::Server::Form::User::Preferences->new($user->id);
    $c->stash->{form} = $form;

    $form->update_from_form ($c->req->params)
        if($c->form_posted);

    $c->stash->{template} = 'user/preferences.tt';
}

=head2 donate

Check the status of donations and ask for one.

=cut

sub donate : Local
{
    my ($self, $c) = @_;
    die "Not implemented";
}

=head1 LICENSE 

This software is provided "as is", without warranty of any kind, express or
implied, including  but not limited  to the warranties of  merchantability,
fitness for a particular purpose and noninfringement. In no event shall the
authors or  copyright  holders be  liable for any claim,  damages or  other
liability, whether  in an  action of  contract, tort  or otherwise, arising
from,  out of  or in  connection with  the software or  the  use  or  other
dealings in the software.

GPL - The GNU General Public License    http://www.gnu.org/licenses/gpl.txt
Permits anyone the right to use and modify the software without limitations
as long as proper  credits are given  and the original  and modified source
code are included. Requires  that the final product, software derivate from
the original  source or any  software  utilizing a GPL  component, such  as
this, is also licensed under the GPL license.

=cut

1;
